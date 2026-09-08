package web

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/abdul-mohsen/deployment/dashboard/internal/dokku"
)

func TestSnapshotSerializationKeepsLegacyFieldsAndAddsObservability(t *testing.T) {
	payload := snapshotJSON(appSnapshot{
		Healthy:   true,
		UpdatedAt: time.Now(),
		Apps: []dokku.App{{
			Name: "acme-backend", Role: "backend", State: "running",
			Image: "dokku/acme-backend:latest", Version: "v1.2.3", HTTPCode: "200",
			Internal: dokku.HealthCheck{Status: "healthy", HTTPCode: "200"},
			External: dokku.HealthCheck{Status: "unavailable", HTTPCode: "000", Reason: "external route unavailable: connection refused"},
			Identity: dokku.BuildIdentity{
				ImageRef:       "registry.example/api:v1.2.3",
				Digest:         "sha256:abc",
				Source:         "https://github.com/example/api",
				WorkflowRunID:  "42",
				WorkflowRunURL: "https://github.com/example/api/actions/runs/42",
				BuiltAt:        "2026-09-07T10:00:00Z",
				Status:         "verified",
			},
		}},
	})

	var decoded map[string]any
	if err := json.Unmarshal([]byte(payload), &decoded); err != nil {
		t.Fatalf("snapshot JSON is invalid: %v", err)
	}
	if decoded["healthy"] != true || decoded["stale"] != false {
		t.Fatalf("legacy/top-level fields changed: %+v", decoded)
	}
	apps := decoded["apps"].([]any)
	app := apps[0].(map[string]any)
	for _, key := range []string{"image", "version", "http", "identity", "internal_health", "external_probe"} {
		if _, ok := app[key]; !ok {
			t.Fatalf("missing additive field %q in %s", key, payload)
		}
	}
	if !strings.Contains(payload, "external route unavailable") {
		t.Fatalf("actionable external reason missing: %s", payload)
	}
	for _, field := range []string{`"workflow_run_id":"42"`, `"workflow_run_url":"https://github.com/example/api/actions/runs/42"`, `"built_at":"2026-09-07T10:00:00Z"`} {
		if !strings.Contains(payload, field) {
			t.Fatalf("canonical identity field missing: %s", field)
		}
	}
}

func TestSnapshotStale(t *testing.T) {
	stale := appSnapshot{UpdatedAt: time.Now().Add(-snapshotStaleAfter - time.Second)}
	if !snapshotIsStale(stale, time.Now()) {
		t.Fatal("expected old snapshot to be stale")
	}
	fresh := appSnapshot{UpdatedAt: time.Now().Add(-time.Second)}
	if snapshotIsStale(fresh, time.Now()) {
		t.Fatal("expected recent snapshot to be fresh")
	}
}

func TestSnapshotStatusSeparatesDokkuLivenessFromProbeDegradation(t *testing.T) {
	snap := appSnapshot{
		Healthy:   true,
		UpdatedAt: time.Now(),
		Apps: []dokku.App{{
			Liveness: dokku.HealthCheck{Status: "healthy"},
			Internal: dokku.HealthCheck{Status: "healthy", HTTPCode: "200"},
			External: dokku.HealthCheck{Status: "unavailable", HTTPCode: "000"},
			Identity: dokku.BuildIdentity{Status: "verified"},
		}},
	}
	if got := snapshotStatus(snap, false); got != "degraded" {
		t.Fatalf("snapshot status = %q, want degraded", got)
	}
}
