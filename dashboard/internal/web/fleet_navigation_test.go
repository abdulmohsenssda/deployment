package web

import (
	"encoding/json"
	"html/template"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/abdul-mohsen/deployment/dashboard/internal/config"
	"github.com/abdul-mohsen/deployment/dashboard/internal/dokku"
)

func TestHandleIndexAppPresentIncludesOpenDestination(t *testing.T) {
	s := newFleetNavigationTestServer(t, []dokku.App{{
		Name:   "acme-frontend",
		Role:   "frontend",
		Tenant: "acme",
		State:  "running",
		Domains: []string{
			"acme.example.test",
		},
	}})

	body := executeIndexForTest(t, s)
	bootstrap := fleetBootstrapFromHTML(t, body)

	if got := bootstrap.Open["acme"].URL; got != "http://acme.example.test" {
		t.Fatalf("fleet open URL = %q, want %q", got, "http://acme.example.test")
	}
	if len(bootstrap.Apps) != 1 {
		t.Fatalf("fleet bootstrap apps = %d, want 1", len(bootstrap.Apps))
	}
	if !strings.Contains(body, `class="btn-action js-open" target="_blank"`) {
		t.Fatal("fleet template is missing the Open action")
	}
	if strings.Contains(body, `class="btn-action js-open" href="#"`) {
		t.Fatal("fleet Open action must not use a placeholder href")
	}
}

func TestHandleIndexMissingURLIncludesUnavailableState(t *testing.T) {
	s := newFleetNavigationTestServer(t, []dokku.App{{
		Name:   "acme-frontend",
		Role:   "frontend",
		Tenant: "acme",
		State:  "running",
	}})

	body := executeIndexForTest(t, s)
	bootstrap := fleetBootstrapFromHTML(t, body)
	state := bootstrap.Open["acme"]

	if state.URL != "" {
		t.Fatalf("fleet open URL = %q, want empty URL", state.URL)
	}
	if state.Unavailable != "No public URL configured" {
		t.Fatalf("fleet unavailable reason = %q, want %q", state.Unavailable, "No public URL configured")
	}
	if !strings.Contains(body, `js-open-unavailable`) {
		t.Fatal("fleet template is missing the visible unavailable state")
	}
}

func TestHandleIndexNoAppsHasNoOpenDestinations(t *testing.T) {
	body := executeIndexForTest(t, newFleetNavigationTestServer(t, nil))
	bootstrap := fleetBootstrapFromHTML(t, body)

	if len(bootstrap.Apps) != 0 {
		t.Fatalf("fleet bootstrap apps = %d, want 0", len(bootstrap.Apps))
	}
	if len(bootstrap.Open) != 0 {
		t.Fatalf("fleet open states = %d, want 0", len(bootstrap.Open))
	}
	if strings.Contains(body, `"acme"`) {
		t.Fatal("empty fleet response unexpectedly contains a tenant")
	}
}

func TestFleetOpenStatePrefersRunningBackendWhenFrontendIsUnavailable(t *testing.T) {
	state := fleetOpenStateForApps([]dokku.App{
		{
			Name:    "acme-frontend",
			Role:    "frontend",
			Tenant:  "acme",
			State:   "stopped",
			Domains: []string{"acme.example.test"},
		},
		{
			Name:    "acme-backend",
			Role:    "backend",
			Tenant:  "acme",
			State:   "running",
			Domains: []string{"api.example.test"},
		},
	})

	if state.URL != "http://api.example.test" {
		t.Fatalf("fleet open URL = %q, want %q", state.URL, "http://api.example.test")
	}
	if state.Unavailable != "" {
		t.Fatalf("fleet unavailable reason = %q, want empty", state.Unavailable)
	}
}

func newFleetNavigationTestServer(t *testing.T, apps []dokku.App) *server {
	t.Helper()

	funcs := template.FuncMap{
		"join":     strings.Join,
		"now":      func() string { return time.Now().Format("2006-01-02 15:04:05") },
		"stateClr": stateClass,
		"httpClr":  httpClass,
		"json":     templateJSON,
	}
	pages := map[string]*template.Template{
		"index.html": template.Must(template.New("").Funcs(funcs).ParseFS(
			tplFS,
			"templates/_layout.html",
			"templates/palette.html",
			"templates/index.html",
		)),
	}

	return &server{
		cfg:       config.Config{EnvName: "test", BaseDomain: "example.test"},
		pages:     pages,
		snapshots: &snapshotCache{snap: appSnapshot{Apps: apps}},
	}
}

func executeIndexForTest(t *testing.T, s *server) string {
	t.Helper()

	rec := httptest.NewRecorder()
	s.handleIndex(rec, httptest.NewRequest("GET", "/", nil))
	if rec.Code != 200 {
		t.Fatalf("index status = %d, want 200", rec.Code)
	}
	return rec.Body.String()
}

func fleetBootstrapFromHTML(t *testing.T, body string) fleetBootstrap {
	t.Helper()

	const startTag = `<script id="fleet-bootstrap" type="application/json">`
	start := strings.Index(body, startTag)
	if start < 0 {
		t.Fatal("fleet bootstrap script missing")
	}
	start += len(startTag)
	end := strings.Index(body[start:], "</script>")
	if end < 0 {
		t.Fatal("fleet bootstrap script is not closed")
	}

	var bootstrap fleetBootstrap
	if err := json.Unmarshal([]byte(body[start:start+end]), &bootstrap); err != nil {
		t.Fatalf("decode fleet bootstrap: %v", err)
	}
	return bootstrap
}
