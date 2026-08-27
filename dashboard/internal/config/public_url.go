package config

import (
	"fmt"
	"net"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

var publicHostLabel = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$`)
var publicTenantLabel = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$`)

// ValidatePublicURL validates the public URL settings used by the dashboard
// and by links it emits. Production dashboards must use a real HTTPS domain.
func (c Config) ValidatePublicURL() error {
	scheme := c.publicProtocol()
	if scheme != "http" && scheme != "https" {
		return fmt.Errorf("PUBLIC_PROTOCOL must be http or https (got %q)", c.PublicProtocol)
	}
	if c.isProduction() && scheme != "https" {
		return fmt.Errorf("production public URLs must use HTTPS (PUBLIC_PROTOCOL=%q)", c.PublicProtocol)
	}

	domain, explicitScheme, err := parsePublicHost(c.BaseDomain)
	if err != nil {
		return fmt.Errorf("BASE_DOMAIN: %w", err)
	}
	if explicitScheme != "" {
		return fmt.Errorf("BASE_DOMAIN must contain a hostname only, not a URL scheme")
	}
	if c.isProduction() && isLocalPublicHost(domain) {
		return fmt.Errorf("production BASE_DOMAIN must not be localhost, localtest.me, or a loopback address")
	}
	return nil
}

// PublicBaseURL returns the canonical public origin used for generated links.
// It returns an empty string when the configuration is invalid.
func (c Config) PublicBaseURL() string {
	scheme, domain, err := c.publicURLParts()
	if err != nil {
		return ""
	}
	return scheme + "://" + domain
}

// PublicURLForHost returns a canonical public URL for a host or absolute URL.
// The configured scheme is always used, so all generated links share one
// origin. Explicit HTTP input is rejected for production configurations.
func (c Config) PublicURLForHost(raw string) (string, error) {
	scheme, _, err := c.publicURLParts()
	if err != nil {
		return "", err
	}
	host, inputScheme, err := parsePublicHost(raw)
	if err != nil {
		return "", err
	}
	if c.isProduction() && inputScheme != "" && inputScheme != "https" {
		return "", fmt.Errorf("production public URLs must not use %q", inputScheme)
	}
	if c.isProduction() && isLocalPublicHost(host) {
		return "", fmt.Errorf("production public URLs must not target localhost, localtest.me, or a loopback address")
	}
	return scheme + "://" + host, nil
}

// PublicURLForTenant returns the public site URL for a tenant. TenantPrefix
// is applied only when it is not already present, matching tenant_full_name in
// the deployment scripts.
func (c Config) PublicURLForTenant(tenant string) (string, error) {
	label := c.publicTenantLabel(tenant)
	if label == "" {
		return "", fmt.Errorf("invalid tenant name %q", tenant)
	}
	_, baseDomain, err := c.publicURLParts()
	if err != nil {
		return "", err
	}
	baseHost, _, err := parsePublicHost(baseDomain)
	if err != nil {
		return "", err
	}
	baseName, port := splitPublicHostPort(baseHost)
	if net.ParseIP(baseName) != nil {
		return "", fmt.Errorf("BASE_DOMAIN must be a DNS name to generate tenant URLs")
	}
	tenantHost := label + "." + baseName
	if port != "" {
		tenantHost = net.JoinHostPort(tenantHost, port)
	}
	return c.PublicURLForHost(tenantHost)
}

// PublicURLForApp returns the public site URL represented by a Dokku app name.
// Both frontend and backend app names map to their tenant's canonical site
// URL; backend app URLs are not exposed as public links by the dashboard.
func (c Config) PublicURLForApp(app string) (string, error) {
	app = strings.TrimSpace(strings.ToLower(app))
	switch {
	case strings.HasSuffix(app, "-backend"):
		app = strings.TrimSuffix(app, "-backend")
	case strings.HasSuffix(app, "-frontend"):
		app = strings.TrimSuffix(app, "-frontend")
	}
	return c.PublicURLForTenant(app)
}

func (c Config) publicURLParts() (string, string, error) {
	scheme := c.publicProtocol()
	if scheme != "http" && scheme != "https" {
		return "", "", fmt.Errorf("PUBLIC_PROTOCOL must be http or https (got %q)", c.PublicProtocol)
	}
	domain, explicitScheme, err := parsePublicHost(c.BaseDomain)
	if err != nil {
		return "", "", fmt.Errorf("BASE_DOMAIN: %w", err)
	}
	if explicitScheme != "" {
		return "", "", fmt.Errorf("BASE_DOMAIN must contain a hostname only, not a URL scheme")
	}
	if c.isProduction() {
		if scheme != "https" {
			return "", "", fmt.Errorf("production public URLs must use HTTPS")
		}
		if isLocalPublicHost(domain) {
			return "", "", fmt.Errorf("production BASE_DOMAIN must not be localhost, localtest.me, or a loopback address")
		}
	}
	return scheme, domain, nil
}

func (c Config) publicProtocol() string {
	if protocol := strings.ToLower(strings.TrimSpace(c.PublicProtocol)); protocol != "" {
		return protocol
	}
	if c.isProduction() {
		return "https"
	}
	return "http"
}

func (c Config) isProduction() bool {
	switch strings.ToLower(strings.TrimSpace(c.EnvName)) {
	case "prod", "production":
		return true
	default:
		return false
	}
}

func (c Config) publicTenantLabel(tenant string) string {
	label := strings.ToLower(strings.TrimSpace(tenant))
	prefix := normalizeTenantPrefix(c.TenantPrefix)
	if prefix != "" && !strings.HasPrefix(label, prefix) {
		label = prefix + label
	}
	if !publicTenantLabel.MatchString(label) {
		return ""
	}
	return label
}

func normalizeBaseDomain(raw string) (string, error) {
	host, scheme, err := parsePublicHost(raw)
	if err != nil {
		return "", err
	}
	if scheme != "" {
		return "", fmt.Errorf("must contain a hostname only, not a URL scheme")
	}
	return host, nil
}

func parsePublicHost(raw string) (host, scheme string, err error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", "", fmt.Errorf("value is required")
	}
	if strings.ContainsAny(raw, " \t\r\n") {
		return "", "", fmt.Errorf("value must not contain whitespace")
	}
	if strings.HasPrefix(raw, "//") {
		return "", "", fmt.Errorf("value must contain a hostname, not a protocol-relative URL")
	}

	explicitScheme := strings.Contains(raw, "://")
	candidate := raw
	if !explicitScheme && !strings.HasPrefix(candidate, "//") {
		candidate = "//" + candidate
	}
	parsed, err := url.Parse(candidate)
	if err != nil {
		return "", "", fmt.Errorf("invalid host %q: %w", raw, err)
	}
	if explicitScheme {
		scheme = strings.ToLower(parsed.Scheme)
		if scheme != "http" && scheme != "https" {
			return "", "", fmt.Errorf("unsupported URL scheme %q", parsed.Scheme)
		}
	}
	if parsed.User != nil {
		return "", "", fmt.Errorf("userinfo is not allowed")
	}
	if parsed.Path != "" && parsed.Path != "/" {
		return "", "", fmt.Errorf("path is not allowed")
	}
	if parsed.RawQuery != "" || parsed.Fragment != "" {
		return "", "", fmt.Errorf("query and fragment are not allowed")
	}
	hostname := strings.TrimSuffix(strings.ToLower(parsed.Hostname()), ".")
	if !validPublicHostname(hostname) {
		return "", "", fmt.Errorf("invalid hostname %q", hostname)
	}
	port := parsed.Port()
	if port != "" {
		n, parseErr := strconv.Atoi(port)
		if parseErr != nil || n < 1 || n > 65535 {
			return "", "", fmt.Errorf("invalid port %q", port)
		}
	}
	if port != "" {
		host = net.JoinHostPort(hostname, port)
	} else if strings.Contains(hostname, ":") {
		host = "[" + hostname + "]"
	} else {
		host = hostname
	}
	return host, scheme, nil
}

func validPublicHostname(hostname string) bool {
	if hostname == "" {
		return false
	}
	if net.ParseIP(hostname) != nil {
		return true
	}
	if len(hostname) > 253 {
		return false
	}
	for _, label := range strings.Split(hostname, ".") {
		if !publicHostLabel.MatchString(label) {
			return false
		}
	}
	return true
}

func isLocalPublicHost(host string) bool {
	hostname, _ := splitPublicHostPort(host)
	hostname = strings.TrimSuffix(strings.ToLower(hostname), ".")
	if hostname == "localhost" || strings.HasSuffix(hostname, ".localhost") ||
		hostname == "localtest.me" || strings.HasSuffix(hostname, ".localtest.me") {
		return true
	}
	ip := net.ParseIP(hostname)
	return ip != nil && (ip.IsLoopback() || ip.IsUnspecified())
}

func splitPublicHostPort(host string) (hostname, port string) {
	hostname = host
	if strings.HasPrefix(host, "[") {
		if h, p, err := net.SplitHostPort(host); err == nil {
			return h, p
		}
		return strings.Trim(host, "[]"), ""
	}
	if i := strings.LastIndexByte(host, ':'); i > -1 && !strings.Contains(host[i+1:], ":") {
		if _, err := strconv.Atoi(host[i+1:]); err == nil {
			return host[:i], host[i+1:]
		}
	}
	return hostname, ""
}
