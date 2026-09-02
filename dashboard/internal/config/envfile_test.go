package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestUpdateEnvFileValueUpdatesExistingKey(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dashboard.env")
	input := "# dashboard\nADMIN_USER=admin\nADMIN_PASSWORD_HASH=old\nSESSION_KEY=abc\n"
	if err := os.WriteFile(path, []byte(input), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := UpdateEnvFileValue(path, "ADMIN_PASSWORD_HASH", "$2a$10$new/hash"); err != nil {
		t.Fatalf("UpdateEnvFileValue: %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	out := string(data)
	if !strings.Contains(out, "ADMIN_PASSWORD_HASH='$2a$10$new/hash'") {
		t.Fatalf("password hash was not updated and quoted:\n%s", out)
	}
	if !strings.Contains(out, "ADMIN_USER=admin") || !strings.Contains(out, "SESSION_KEY=abc") {
		t.Fatalf("unrelated env values were not preserved:\n%s", out)
	}
}

func TestUpdateEnvFileValueAppendsMissingKey(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dashboard.env")
	if err := os.WriteFile(path, []byte("ADMIN_USER=admin\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := UpdateEnvFileValue(path, "ADMIN_PASSWORD_HASH", "$2a$10$new/hash"); err != nil {
		t.Fatalf("UpdateEnvFileValue: %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	out := string(data)
	if !strings.HasSuffix(out, "ADMIN_PASSWORD_HASH='$2a$10$new/hash'\n") {
		t.Fatalf("password hash was not appended:\n%s", out)
	}
}

func TestUpdateEnvFileValuePreservesExportPrefix(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dashboard.env")
	if err := os.WriteFile(path, []byte("export ADMIN_PASSWORD_HASH=old\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := UpdateEnvFileValue(path, "ADMIN_PASSWORD_HASH", "new"); err != nil {
		t.Fatalf("UpdateEnvFileValue: %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := string(data); got != "export ADMIN_PASSWORD_HASH='new'\n" {
		t.Fatalf("unexpected output: %q", got)
	}
}

func TestOverrideEnvFileValuesBeatsComposeValues(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.env")
	if err := os.WriteFile(path, []byte("BASE_DOMAIN=dev.ifritah.com\nPUBLIC_PROTOCOL=https\nADMIN_USER=config-user\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BASE_DOMAIN", "localhost")
	t.Setenv("PUBLIC_PROTOCOL", "http")
	t.Setenv("ADMIN_USER", "compose-user")

	if err := OverrideEnvFileValues(path, "BASE_DOMAIN", "PUBLIC_PROTOCOL"); err != nil {
		t.Fatalf("OverrideEnvFileValues: %v", err)
	}
	if got := os.Getenv("BASE_DOMAIN"); got != "dev.ifritah.com" {
		t.Fatalf("BASE_DOMAIN = %q, want dev.ifritah.com", got)
	}
	if got := os.Getenv("PUBLIC_PROTOCOL"); got != "https" {
		t.Fatalf("PUBLIC_PROTOCOL = %q, want https", got)
	}
	if got := os.Getenv("ADMIN_USER"); got != "compose-user" {
		t.Fatalf("ADMIN_USER = %q, want compose-user", got)
	}
}

func TestNormalizeTenantPrefix(t *testing.T) {
	tests := map[string]string{
		"":         "",
		"dev":      "dev-",
		"dev-":     "dev-",
		"Prod":     "prod-",
		"qa env":   "qa-env-",
		"---":      "",
		"dev_acme": "dev-acme-",
	}

	for input, want := range tests {
		if got := normalizeTenantPrefix(input); got != want {
			t.Fatalf("normalizeTenantPrefix(%q) = %q, want %q", input, got, want)
		}
	}
}
