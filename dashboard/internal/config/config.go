// Package config loads dashboard configuration from environment variables.
package config

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// Config is the runtime configuration for the dashboard.
type Config struct {
	EnvName          string // e.g. "dev" / "prod" — shown in the header.
	Listen           string // host:port to listen on.
	DockerBin        string // path to the docker binary.
	DokkuContainer   string // name of the dokku-in-docker container.
	BaseDomain       string // base domain shown for app URLs.
	PublicProtocol   string // scheme for generated public URLs (http or https).
	AdminUser        string // single admin username.
	AdminHash        string // bcrypt hash of the admin password.
	SessionKey       []byte // cookie signing key.
	LogBufferLines   int    // ring-buffer size per app for log aggregation.
	CookieSecure     bool   // set Secure flag on session cookie.
	ScriptsHostPath  string // host path to /opt/deployment (for sidecar runner).
	RunnerImage      string // image used to execute deployment scripts.
	ConfigFile       string // optional --config file path inside runner.
	DashboardEnvFile string // optional writable env file for dashboard credentials.
	TenantPrefix     string // optional tenant name prefix, e.g. "dev-" or "prod-".
	TenantStateDir   string // directory for per-tenant JSON state files (auto_redeploy etc.).
	BackupDir        string // host path where backup files are stored.
	MySQLHost        string // MySQL host for accounting export queries.
	MySQLPort        string // MySQL port for accounting export queries.
}

// Load reads configuration from the process environment.
//
// Required:
//
//	ADMIN_USER, ADMIN_PASSWORD_HASH (bcrypt)
//
// Optional with defaults:
//
//	DASHBOARD_ENV=dev|prod    (default "dev")
//	LISTEN=:8080
//	DOCKER_BIN=docker
//	DOKKU_CONTAINER=dokku
//	BASE_DOMAIN=localhost
//	PUBLIC_PROTOCOL=http|https (default "http", or "https" for prod)
//	SESSION_KEY=<hex>         (auto-generated if missing — sessions reset on restart)
//	LOG_BUFFER_LINES=2000
//	COOKIE_SECURE=false
func Load() (Config, error) {
	c := Config{
		EnvName:          envOr("DASHBOARD_ENV", "dev"),
		Listen:           envOr("LISTEN", ":8080"),
		DockerBin:        envOr("DOCKER_BIN", "docker"),
		DokkuContainer:   envOr("DOKKU_CONTAINER", "dokku"),
		BaseDomain:       envOr("BASE_DOMAIN", "localhost"),
		PublicProtocol:   envOr("PUBLIC_PROTOCOL", ""),
		AdminUser:        os.Getenv("ADMIN_USER"),
		AdminHash:        os.Getenv("ADMIN_PASSWORD_HASH"),
		LogBufferLines:   envInt("LOG_BUFFER_LINES", 2000),
		CookieSecure:     strings.EqualFold(os.Getenv("COOKIE_SECURE"), "true"),
		ScriptsHostPath:  envOr("SCRIPTS_HOST_PATH", ""),
		RunnerImage:      envOr("SCRIPT_RUNNER_IMAGE", "mysql:8.0"),
		ConfigFile:       envOr("DEPLOY_CONFIG_FILE", ""),
		DashboardEnvFile: envOr("DASHBOARD_ENV_FILE", ""),
		TenantPrefix:     normalizeTenantPrefix(os.Getenv("TENANT_NAME_PREFIX")),
		TenantStateDir:   envOr("TENANT_STATE_DIR", "/opt/tenant-state"),
		BackupDir:        envOr("BACKUP_DIR", "/opt/tenant-backups"),
		MySQLHost:        envOr("MYSQL_HOST", "127.0.0.1"),
		MySQLPort:        envOr("MYSQL_PORT", "3306"),
	}
	if baseDomain, err := normalizeBaseDomain(c.BaseDomain); err != nil {
		return c, fmt.Errorf("BASE_DOMAIN: %w", err)
	} else {
		c.BaseDomain = baseDomain
	}
	c.PublicProtocol = c.publicProtocol()
	if err := c.ValidatePublicURL(); err != nil {
		return c, err
	}
	if c.AdminUser == "" || c.AdminHash == "" {
		return c, fmt.Errorf("ADMIN_USER and ADMIN_PASSWORD_HASH are required")
	}
	if k := os.Getenv("SESSION_KEY"); k != "" {
		raw, err := hex.DecodeString(k)
		if err != nil {
			return c, fmt.Errorf("SESSION_KEY must be hex: %w", err)
		}
		c.SessionKey = raw
	} else {
		c.SessionKey = make([]byte, 32)
		if _, err := rand.Read(c.SessionKey); err != nil {
			return c, err
		}
	}
	return c, nil
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envInt(k string, def int) int {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func normalizeTenantPrefix(prefix string) string {
	prefix = strings.ToLower(strings.TrimSpace(prefix))
	if prefix == "" {
		return ""
	}
	var b strings.Builder
	for _, r := range prefix {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-' {
			b.WriteRune(r)
		} else {
			b.WriteByte('-')
		}
	}
	out := strings.Trim(b.String(), "-")
	if out == "" {
		return ""
	}
	return out + "-"
}
