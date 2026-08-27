package config

import (
	"strings"
	"testing"
)

func setLoadURLTestEnv(t *testing.T) {
	t.Helper()
	t.Setenv("ADMIN_USER", "admin")
	t.Setenv("ADMIN_PASSWORD_HASH", "not-a-real-hash")
	t.Setenv("SESSION_KEY", strings.Repeat("ab", 32))
	t.Setenv("TENANT_NAME_PREFIX", "")
}

func TestLoadProductionPublicURLDefaultsToHTTPS(t *testing.T) {
	setLoadURLTestEnv(t)
	t.Setenv("DASHBOARD_ENV", "prod")
	t.Setenv("BASE_DOMAIN", "Example.COM")
	t.Setenv("PUBLIC_PROTOCOL", "")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.PublicProtocol != "https" {
		t.Fatalf("PublicProtocol = %q, want https", cfg.PublicProtocol)
	}
	if cfg.BaseDomain != "example.com" {
		t.Fatalf("BaseDomain = %q, want example.com", cfg.BaseDomain)
	}
	if got := cfg.PublicBaseURL(); got != "https://example.com" {
		t.Fatalf("PublicBaseURL() = %q, want https://example.com", got)
	}

	t.Setenv("TENANT_NAME_PREFIX", "prod-")
	cfg.TenantPrefix = normalizeTenantPrefix("prod-")
	got, err := cfg.PublicURLForTenant("acme")
	if err != nil {
		t.Fatalf("PublicURLForTenant: %v", err)
	}
	if got != "https://prod-acme.example.com" {
		t.Fatalf("PublicURLForTenant() = %q, want https://prod-acme.example.com", got)
	}
}

func TestLoadProductionRejectsUnsafePublicURLSettings(t *testing.T) {
	tests := []struct {
		name       string
		baseDomain string
		protocol   string
	}{
		{name: "localhost", baseDomain: "localhost", protocol: "https"},
		{name: "localtest.me", baseDomain: "localtest.me", protocol: "https"},
		{name: "http", baseDomain: "example.com", protocol: "http"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			setLoadURLTestEnv(t)
			t.Setenv("DASHBOARD_ENV", "production")
			t.Setenv("BASE_DOMAIN", tc.baseDomain)
			t.Setenv("PUBLIC_PROTOCOL", tc.protocol)

			if _, err := Load(); err == nil {
				t.Fatalf("Load succeeded for unsafe production URL settings")
			}
		})
	}
}

func TestPublicURLForHostRejectsHTTPInProduction(t *testing.T) {
	cfg := Config{EnvName: "prod", BaseDomain: "example.com"}

	if _, err := cfg.PublicURLForHost("http://acme.example.com"); err == nil {
		t.Fatal("PublicURLForHost accepted an HTTP production URL")
	}
	if _, err := cfg.PublicURLForHost("//acme.example.com"); err == nil {
		t.Fatal("PublicURLForHost accepted a protocol-relative production URL")
	}
	if _, err := cfg.PublicURLForHost("localhost"); err == nil {
		t.Fatal("PublicURLForHost accepted a localhost production URL")
	}
}

func TestLocalPublicURLRemainsConfigurable(t *testing.T) {
	cfg := Config{
		EnvName:        "dev",
		BaseDomain:     "localhost",
		PublicProtocol: "http",
		TenantPrefix:   "dev-",
	}

	if got, err := cfg.PublicURLForTenant("acme"); err != nil {
		t.Fatalf("PublicURLForTenant: %v", err)
	} else if got != "http://dev-acme.localhost" {
		t.Fatalf("PublicURLForTenant() = %q, want http://dev-acme.localhost", got)
	}
	if got, err := cfg.PublicURLForApp("dev-acme-frontend"); err != nil {
		t.Fatalf("PublicURLForApp: %v", err)
	} else if got != "http://dev-acme.localhost" {
		t.Fatalf("PublicURLForApp() = %q, want http://dev-acme.localhost", got)
	}
	if got, err := cfg.PublicURLForHost("http://localhost"); err != nil {
		t.Fatalf("PublicURLForHost: %v", err)
	} else if got != "http://localhost" {
		t.Fatalf("PublicURLForHost() = %q, want http://localhost", got)
	}
}
