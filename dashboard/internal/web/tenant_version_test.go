package web

import (
	"testing"

	"github.com/abdul-mohsen/deployment/dashboard/internal/dokku"
)

// The tenant Sync-version form must be pre-filled with the tenant's currently
// deployed image tag so the details reflect the selected dev tag rather than
// the fleet default. Regression test for "details show v0.0.1 instead of the
// selected dev tag".
func TestTenantSyncVersion_PrefersDeployedVersion(t *testing.T) {
	backend := &dokku.App{Name: "acme-backend", Role: "backend", Version: "dev"}
	frontend := &dokku.App{Name: "acme-frontend", Role: "frontend", Version: "dev"}

	if got := tenantSyncVersion(backend, frontend, "v0.0.1"); got != "dev" {
		t.Fatalf("tenantSyncVersion = %q, want %q (deployed version must win over default)", got, "dev")
	}
}

// When the backend tag is missing, fall back to the frontend tag before the
// default.
func TestTenantSyncVersion_FallsBackToFrontendThenDefault(t *testing.T) {
	backend := &dokku.App{Name: "acme-backend", Role: "backend", Version: ""}
	frontend := &dokku.App{Name: "acme-frontend", Role: "frontend", Version: "feature-x"}
	if got := tenantSyncVersion(backend, frontend, "v0.0.1"); got != "feature-x" {
		t.Fatalf("tenantSyncVersion = %q, want %q", got, "feature-x")
	}

	if got := tenantSyncVersion(nil, nil, "v0.0.1"); got != "v0.0.1" {
		t.Fatalf("tenantSyncVersion = %q, want default %q", got, "v0.0.1")
	}
}
