package web

import (
	"bytes"
	"encoding/json"
	"fmt"
	"html/template"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/abdul-mohsen/deployment/dashboard/internal/dokku"
	"github.com/abdul-mohsen/deployment/dashboard/internal/scripts"
)

func TestBuildReleaseViewsMarksFailedDeploymentBroken(t *testing.T) {
	catalog := []scripts.ImageVersion{{Tag: "v0.0.1", Status: "ready", BackendImage: "repo/api:v0.0.1", FrontendImage: "repo/web:v0.0.1"}}
	apps := []dokku.App{
		{Name: "acme-backend", Role: "backend", Version: "v0.0.1", Image: "repo/api:v0.0.1", State: "running", Identity: dokku.BuildIdentity{Status: "verified"}},
		{Name: "acme-frontend", Role: "frontend", Version: "v0.0.1", Image: "repo/web:v0.0.1", State: "restarting", Identity: dokku.BuildIdentity{Status: "verified"}},
	}

	views := buildReleaseViews(catalog, apps)
	if len(views) != 1 {
		t.Fatalf("expected 1 release view, got %d", len(views))
	}
	if !views[0].Broken || views[0].Status != "broken" {
		t.Fatalf("expected failed deployed app to mark release broken, got %+v", views[0])
	}
	if views[0].Deployed != 2 || views[0].Failed != 1 {
		t.Fatalf("unexpected deployment counts: %+v", views[0])
	}
}

func TestBuildReleaseViewsIgnoresChannelTags(t *testing.T) {
	apps := []dokku.App{{Name: "dev-backend", Role: "backend", Version: "dev", State: "stopped"}}
	if views := buildReleaseViews(nil, apps); len(views) != 0 {
		t.Fatalf("expected channel tags to be ignored, got %+v", views)
	}
}

func TestBuildReleaseViewsMatchesIndependentComponentVersions(t *testing.T) {
	catalog := []scripts.ImageVersion{{
		Tag:             "v0.0.3",
		BackendVersion:  "v0.0.3",
		FrontendVersion: "v0.0.2",
		BackendImage:    "repo/api:v0.0.3",
		FrontendImage:   "repo/web:v0.0.2",
		Status:          "not-ready",
	}}
	apps := []dokku.App{
		{Name: "acme-backend", Role: "backend", Version: "v0.0.3", Image: "repo/api:v0.0.3", State: "running", Identity: dokku.BuildIdentity{Status: "verified"}},
		{Name: "acme-frontend", Role: "frontend", Version: "v0.0.2", Image: "repo/web:v0.0.2", State: "running", Identity: dokku.BuildIdentity{Status: "verified"}},
	}
	views := buildReleaseViews(catalog, apps)
	if len(views) != 1 || views[0].Deployed != 2 {
		t.Fatalf("expected both component versions to map to one release: %+v", views)
	}
}

func TestBuildReleaseViewsDoesNotClaimMissingProvenanceAsSuccessful(t *testing.T) {
	catalog := []scripts.ImageVersion{{Tag: "v1.2.3", Status: "ready", BackendImage: "repo/api:v1.2.3"}}
	apps := []dokku.App{{
		Name: "acme-backend", Role: "backend", Version: "v1.2.3",
		Image: "dokku/acme-backend:latest", State: "running",
		Identity: dokku.BuildIdentity{Status: "missing", Reason: "missing digest"},
	}}
	views := buildReleaseViews(catalog, apps)
	if len(views) != 1 || !views[0].Broken || views[0].Status != "broken" {
		t.Fatalf("expected missing provenance to be broken: %+v", views)
	}
	if !strings.Contains(views[0].FailureSummary, "provenance") {
		t.Fatalf("missing provenance reason not exposed: %+v", views[0])
	}
}

func TestReleaseTemplateRendersProvenanceAndValidationReason(t *testing.T) {
	funcs := template.FuncMap{
		"join": strings.Join,
		"now":  func() string { return "" },
	}
	page := template.Must(template.New("").Funcs(funcs).ParseFiles("templates/releases.html"))
	view := releaseView{ImageVersion: scripts.ImageVersion{
		Tag:                  "v0.0.4",
		Channel:              "stable",
		Status:               "not-ready",
		BackendVersion:       "v0.0.4",
		FrontendVersion:      "v0.0.3",
		BackendImage:         "owner/api:v0.0.4",
		FrontendImage:        "owner/web:v0.0.3",
		BackendDigest:        "sha256:backend",
		FrontendDigest:       "sha256:frontend",
		BackendSourceCommit:  "backend-full-sha",
		FrontendSourceCommit: "frontend-full-sha",
		ValidationErrors:     []string{"frontend OCI identity metadata has not been validated"},
	}}
	var out bytes.Buffer
	if err := page.ExecuteTemplate(&out, "content", map[string]any{
		"Releases":       []releaseView{view},
		"DefaultVersion": "dev",
	}); err != nil {
		t.Fatal(err)
	}
	body := out.String()
	for _, want := range []string{"owner/api:v0.0.4", "sha256:backend", "backend-full-sha", "frontend OCI identity metadata has not been validated", "not-ready"} {
		if !strings.Contains(body, want) {
			t.Errorf("rendered release page missing %q: %s", want, body)
		}
	}
}

func TestApplyOperationStatusSurfacesFailure(t *testing.T) {
	s := &server{operations: map[string]operationStatus{}}
	s.recordOperation("acme-backend", "update-tenant", fmt.Errorf("image pull failed"))
	apps := []dokku.App{{Name: "acme-backend"}}
	s.applyOperationStatus(apps)
	if apps[0].LastOperation == "" || apps[0].LastFailure != "image pull failed" {
		t.Fatalf("expected operation provenance, got %+v", apps[0])
	}
}

func TestAPIReleasesExposesIndependentDevDefaults(t *testing.T) {
	t.Setenv("BACKEND_IMAGE", "owner/api")
	t.Setenv("FRONTEND_IMAGE", "owner/web")
	t.Setenv("APP_IMAGE_VERSION_DEFAULT", "")
	s := &server{}
	rec := httptest.NewRecorder()
	s.handleAPIReleases(rec, httptest.NewRequest("GET", "/api/releases", nil))
	var payload struct {
		Default           string            `json:"default"`
		DefaultComponents map[string]string `json:"default_components"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Default != "dev" || payload.DefaultComponents["backend"] != "owner/api:dev" ||
		payload.DefaultComponents["frontend"] != "owner/web:dev" {
		t.Fatalf("unexpected release defaults: %+v", payload)
	}
}
