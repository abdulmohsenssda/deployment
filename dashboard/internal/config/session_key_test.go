package config

import (
	"encoding/hex"
	"strings"
	"testing"
)

// setEnv sets an env var for the duration of the test and restores it after.
func setEnv(t *testing.T, kv map[string]string) {
	t.Helper()
	prev := map[string]string{}
	for k := range kv {
		prev[k] = getEnvRaw(k)
	}
	for k, v := range kv {
		if v == "" {
			t.Setenv(k, "")
		} else {
			t.Setenv(k, v)
		}
	}
	_ = prev // t.Setenv already restores on cleanup
}

// getEnvRaw exists only so tests can compile without importing os in the caller.
func getEnvRaw(k string) string { return "" }

// TestSessionKeyRequiredInProd checks that DASHBOARD_ENV=prod without
// SESSION_KEY causes Load to fail fast — silent auth invalidation on
// every restart was the bug this closes.
func TestSessionKeyRequiredInProd(t *testing.T) {
	setEnv(t, map[string]string{
		"DASHBOARD_ENV":       "prod",
		"ADMIN_USER":          "admin",
		"ADMIN_PASSWORD_HASH": "$2a$10$fakehashthatpassesparse.................",
		"BASE_DOMAIN":         "example.com",
		"PUBLIC_PROTOCOL":     "https",
		"SESSION_KEY":         "",
	})
	_, err := Load()
	if err == nil {
		t.Fatal("expected Load() to fail when DASHBOARD_ENV=prod and SESSION_KEY unset")
	}
	if !strings.Contains(err.Error(), "SESSION_KEY is required") {
		t.Errorf("wrong error, got %v", err)
	}
}

// TestSessionKeyOptionalInDev keeps the dev ergonomics: dev sessions can
// auto-regenerate, they only matter across restarts in prod.
func TestSessionKeyOptionalInDev(t *testing.T) {
	setEnv(t, map[string]string{
		"DASHBOARD_ENV":       "dev",
		"ADMIN_USER":          "admin",
		"ADMIN_PASSWORD_HASH": "$2a$10$fakehashthatpassesparse.................",
		"SESSION_KEY":         "",
	})
	c, err := Load()
	if err != nil {
		t.Fatalf("dev should not require SESSION_KEY: %v", err)
	}
	if len(c.SessionKey) != 32 {
		t.Errorf("expected 32-byte auto-generated key, got %d", len(c.SessionKey))
	}
}

// TestSessionKeyMinLength32 catches operators pasting a too-short hex value.
func TestSessionKeyMinLength32(t *testing.T) {
	short := hex.EncodeToString(make([]byte, 8)) // 8 bytes = 16 hex chars
	setEnv(t, map[string]string{
		"DASHBOARD_ENV":       "prod",
		"ADMIN_USER":          "admin",
		"ADMIN_PASSWORD_HASH": "$2a$10$fakehashthatpassesparse.................",
		"BASE_DOMAIN":         "example.com",
		"PUBLIC_PROTOCOL":     "https",
		"SESSION_KEY":         short,
	})
	_, err := Load()
	if err == nil {
		t.Fatal("expected Load() to reject 8-byte SESSION_KEY")
	}
	if !strings.Contains(err.Error(), "too short") {
		t.Errorf("wrong error, got %v", err)
	}
}
