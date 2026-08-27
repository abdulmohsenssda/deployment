package web

import (
	"encoding/json"
	"html/template"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/abdul-mohsen/deployment/dashboard/internal/buildinfo"
	"github.com/go-chi/chi/v5"
)

func TestEmbeddedWebAssetsAreConsistent(t *testing.T) {
	if err := validateEmbeddedWebAssets(); err != nil {
		t.Fatalf("embedded web assets are inconsistent: %v", err)
	}
	manifest, err := embeddedAssetManifest()
	if err != nil {
		t.Fatalf("embedded asset manifest: %v", err)
	}
	for _, name := range []string{"app.css", "app.js", "htmx.min.js"} {
		if manifest.Files[name] == "" {
			t.Errorf("asset %q is missing from the manifest", name)
		}
	}
	for _, name := range []string{"_layout.html", "app.html", "index.html"} {
		if manifest.Templates[name] == "" {
			t.Errorf("template %q is missing from the manifest", name)
		}
	}
	if len(manifest.Digest) != 64 {
		t.Fatalf("asset digest = %q, want sha256 hex", manifest.Digest)
	}
}

func TestEmbeddedWebRoutesAreConsistent(t *testing.T) {
	handler := testRouter(t)
	routes, ok := handler.(chi.Routes)
	if !ok {
		t.Fatalf("router does not expose chi route tree")
	}
	if err := validateEmbeddedWebRoutes(routes); err != nil {
		t.Fatalf("embedded web routes are inconsistent: %v", err)
	}
}

func TestNormalizeRouteReferencePreservesDynamicRouteShape(t *testing.T) {
	got := normalizeRouteReference(`/apps/{{.Name}}/activity?limit={{.Limit}}`)
	if got != "/apps/placeholder/activity" {
		t.Fatalf("normalizeRouteReference() = %q", got)
	}
	if !routePatternMatches(got, "/apps/{name}/activity") {
		t.Fatalf("normalized route %q did not match activity route", got)
	}
}

func TestBuildInfoEndpointIsPublicAndStable(t *testing.T) {
	oldVersion, oldCommit := buildinfo.Version, buildinfo.Commit
	t.Cleanup(func() {
		buildinfo.Version, buildinfo.Commit = oldVersion, oldCommit
	})
	buildinfo.Version = "main"
	buildinfo.Commit = "0123456789abcdef"

	handler := testRouter(t)
	req := httptest.NewRequest(http.MethodGet, "/version", nil)
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("GET /version status = %d, want 200", rr.Code)
	}
	var got buildResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("GET /version returned invalid JSON: %v", err)
	}
	if got.Service != "dokku-dashboard" || got.Version != "main" || got.Commit != "0123456789abcdef" {
		t.Fatalf("GET /version = %+v", got)
	}
	if got.AssetDigest == "" || got.Assets["app.js"] == "" || got.Templates["app.html"] == "" {
		t.Fatalf("GET /version omitted asset identity: %+v", got)
	}
	if rr.Header().Get("X-Dashboard-Commit") != got.Commit {
		t.Fatalf("X-Dashboard-Commit = %q, want %q", rr.Header().Get("X-Dashboard-Commit"), got.Commit)
	}
}

func TestRenderedPageShowsBuildIdentityAndCacheBustsAssets(t *testing.T) {
	oldVersion, oldCommit := buildinfo.Version, buildinfo.Commit
	t.Cleanup(func() {
		buildinfo.Version, buildinfo.Commit = oldVersion, oldCommit
	})
	buildinfo.Version = "release"
	buildinfo.Commit = "fedcba9876543210"

	tpl, err := template.New("").Funcs(template.FuncMap{
		"join":     strings.Join,
		"now":      func() string { return time.Now().Format("2006-01-02 15:04:05") },
		"stateClr": stateClass,
		"httpClr":  httpClass,
		"json":     templateJSON,
	}).Parse(`{{define "content"}}{{end}}`)
	if err == nil {
		_, err = tpl.ParseFS(tplFS, "templates/_layout.html", "templates/palette.html")
	}
	if err != nil {
		t.Fatalf("parse layout: %v", err)
	}

	var rendered strings.Builder
	if err := tpl.ExecuteTemplate(&rendered, "_layout.html", map[string]any{
		"Env":   "test",
		"Build": currentBuildResponse(),
	}); err != nil {
		t.Fatalf("render layout: %v", err)
	}
	body := rendered.String()
	digest := currentBuildResponse().AssetDigest
	for _, want := range []string{
		`build <code>release</code> · commit <code>fedcba9876543210</code>`,
		`/static/app.css?v=` + digest,
		`/static/app.js?v=` + digest,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("rendered page missing %q", want)
		}
	}
}

func TestHealthzPreservesProbeBodyAndExposesBuildHeaders(t *testing.T) {
	handler := testRouter(t)
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK || strings.TrimSpace(rr.Body.String()) != "ok" {
		t.Fatalf("GET /healthz = %d %q, want 200 ok", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-Dashboard-Version") == "" || rr.Header().Get("X-Dashboard-Commit") == "" {
		t.Fatalf("health response omitted build headers: %v", rr.Header())
	}
	if rr.Header().Get("X-Dashboard-Asset-Digest") == "" {
		t.Fatalf("health response omitted asset digest header: %v", rr.Header())
	}
}
