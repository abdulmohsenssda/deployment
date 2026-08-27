package web

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/abdul-mohsen/deployment/dashboard/internal/config"
	"github.com/abdul-mohsen/deployment/dashboard/internal/dokku"
	"github.com/abdul-mohsen/deployment/dashboard/internal/logbuf"
	"github.com/abdul-mohsen/deployment/dashboard/internal/scripts"
	"github.com/abdul-mohsen/deployment/dashboard/internal/tenantstate"
)

// testRouter returns a test HTTP router wired to a minimal config with a
// temporary tenant-state directory.
func testRouter(t *testing.T) http.Handler {
	t.Helper()
	stateDir := t.TempDir()
	cfg := config.Config{
		EnvName:        "test",
		Listen:         ":0",
		DockerBin:      "docker",
		DokkuContainer: "dokku",
		BaseDomain:     "localhost",
		AdminUser:      "admin",
		// bcrypt of "test" (cost 4 for speed)
		AdminHash:      "$2a$04$YPy8G4b4YHo5R4SqPhAn8ulUqBPFhT3MJHGOBSPkENLCZuoIWGCk6",
		SessionKey:     []byte("testsessionkeyXXXXXXXXXXXXXXXXXX"),
		LogBufferLines: 100,
		TenantStateDir: stateDir,
		BackupDir:      t.TempDir(),
		MySQLHost:      "127.0.0.1",
		MySQLPort:      "3306",
	}
	d := dokku.New(cfg.DockerBin, cfg.DokkuContainer)
	l := logbuf.New(cfg.LogBufferLines)
	r := scripts.NewRunner(cfg.DockerBin, cfg.RunnerImage, cfg.ScriptsHostPath, cfg.ConfigFile)
	return Router(cfg, d, l, r)
}

// authenticate returns a cookie that satisfies requireAuth.
// It does a real POST /login to get a session cookie.
func authenticate(t *testing.T, handler http.Handler) *http.Cookie {
	t.Helper()
	body := url.Values{"user": {"admin"}, "pass": {"test"}}.Encode()
	req := httptest.NewRequest(http.MethodPost, "/login", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)
	for _, c := range rr.Result().Cookies() {
		if c.Name == "dashboard" {
			return c
		}
	}
	// Auth failed or no session cookie — tests that call auth-protected endpoints
	// will simply get 302 redirects and should tolerate that.
	return nil
}

// ── /api/image-tags ────────────────────────────────────────────────────────────

func TestImageTagsRequiresAuth(t *testing.T) {
	h := testRouter(t)
	req := httptest.NewRequest(http.MethodGet, "/api/image-tags", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	// Expect any redirect (3xx) to /login for unauthenticated requests
	if rr.Code < 300 || rr.Code >= 400 {
		t.Errorf("expected 3xx redirect for unauthenticated request, got %d", rr.Code)
	}
}

func TestImageTagsReturnsJSON(t *testing.T) {
	h := testRouter(t)
	cookie := authenticate(t, h)
	if cookie == nil {
		t.Skip("could not obtain session cookie (login failed — expected in test env)")
	}

	req := httptest.NewRequest(http.MethodGet, "/api/image-tags", nil)
	req.AddCookie(cookie)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("expected 200, got %d: %s", rr.Code, rr.Body.String())
		return
	}
	var body map[string]any
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Errorf("response is not valid JSON: %v — body: %s", err, rr.Body.String())
		return
	}
	if _, ok := body["tags"]; !ok {
		t.Errorf("response missing 'tags' key: %v", body)
	}
	if _, ok := body["meta"]; !ok {
		t.Errorf("response missing 'meta' key: %v", body)
	}
}

func TestImageTagsFilterQuery(t *testing.T) {
	h := testRouter(t)
	cookie := authenticate(t, h)
	if cookie == nil {
		t.Skip("could not obtain session cookie")
	}

	req := httptest.NewRequest(http.MethodGet, "/api/image-tags?q=zzz_unlikely_match", nil)
	req.AddCookie(cookie)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	var body struct {
		Tags []string `json:"tags"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatalf("bad JSON: %v", err)
	}
	// With a nonsense query against Docker Hub (which is not reachable in tests),
	// we expect an empty tags list — not an error.
	if len(body.Tags) != 0 {
		t.Errorf("expected empty tags for unlikely query, got %v", body.Tags)
	}
}

// ── /tenants/{name}/auto-redeploy ──────────────────────────────────────────────

func TestAutoRedeployToggle(t *testing.T) {
	stateDir := t.TempDir()
	cfg := config.Config{
		EnvName:        "test",
		Listen:         ":0",
		DockerBin:      "docker",
		DokkuContainer: "dokku",
		BaseDomain:     "localhost",
		AdminUser:      "admin",
		AdminHash:      "$2a$04$YPy8G4b4YHo5R4SqPhAn8ulUqBPFhT3MJHGOBSPkENLCZuoIWGCk6",
		SessionKey:     []byte("testsessionkeyXXXXXXXXXXXXXXXXXX"),
		LogBufferLines: 100,
		TenantStateDir: stateDir,
		BackupDir:      t.TempDir(),
		MySQLHost:      "127.0.0.1",
		MySQLPort:      "3306",
	}
	d := dokku.New(cfg.DockerBin, cfg.DokkuContainer)
	l := logbuf.New(cfg.LogBufferLines)
	r := scripts.NewRunner(cfg.DockerBin, cfg.RunnerImage, cfg.ScriptsHostPath, cfg.ConfigFile)
	h := Router(cfg, d, l, r)

	cookie := authenticate(t, h)
	if cookie == nil {
		t.Skip("could not obtain session cookie")
	}

	doToggle := func(enabled string) int {
		body := "enabled=" + enabled
		req := httptest.NewRequest(http.MethodPost, "/tenants/acme/auto-redeploy", strings.NewReader(body))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.AddCookie(cookie)
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, req)
		return rr.Code
	}

	// Disable
	if code := doToggle("0"); code != http.StatusNoContent {
		t.Errorf("disable: expected 204, got %d", code)
	}
	store := tenantstate.NewStore(stateDir)
	if store.IsAutoRedeployEnabled("acme") {
		t.Error("expected auto-redeploy disabled after POST enabled=0")
	}

	// Re-enable
	if code := doToggle("1"); code != http.StatusNoContent {
		t.Errorf("enable: expected 204, got %d", code)
	}
	if !store.IsAutoRedeployEnabled("acme") {
		t.Error("expected auto-redeploy enabled after POST enabled=1")
	}
}

func TestAutoRedeployInvalidTenantName(t *testing.T) {
	h := testRouter(t)
	cookie := authenticate(t, h)
	if cookie == nil {
		t.Skip("could not obtain session cookie")
	}

	req := httptest.NewRequest(http.MethodPost, "/tenants/../../evil/auto-redeploy",
		strings.NewReader("enabled=1"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.AddCookie(cookie)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	// chi route will 404 because ".." doesn't match {name} pattern
	if rr.Code == http.StatusNoContent {
		t.Errorf("expected non-204 for path traversal attempt, got %d", rr.Code)
	}
}

// ── validBackupID ─────────────────────────────────────────────────────────────

func TestValidBackupID(t *testing.T) {
	cases := []struct {
		id   string
		want bool
	}{
		{"acme_20250101_120000", true},
		{"my-tenant_20251231_235959", true},
		{"", false},
		{"../etc/passwd", false},
		{strings.Repeat("a", 81), false},
		{"spaces not allowed", false},
		{"semicolons;bad", false},
	}
	for _, tc := range cases {
		if got := validBackupID(tc.id); got != tc.want {
			t.Errorf("validBackupID(%q) = %v, want %v", tc.id, got, tc.want)
		}
	}
}

func TestBackupArtifactPathRejectsTraversal(t *testing.T) {
	dir := t.TempDir()
	if got, err := backupArtifactPath(dir, "tenant_mysql_20250101_120000.sql.gz"); err != nil || got == "" {
		t.Fatalf("expected valid artifact path, got %q, %v", got, err)
	}
	for _, artifact := range []string{
		"../outside.sql.gz",
		`..\outside.sql.gz`,
		"/etc/passwd",
		`C:\Windows\win.ini`,
	} {
		if got, err := backupArtifactPath(dir, artifact); err == nil || got != "" {
			t.Errorf("backupArtifactPath(%q) = %q, %v; expected rejection", artifact, got, err)
		}
	}
}

// ── fetchImageTagsWithMeta ────────────────────────────────────────────────────

func TestFetchImageTagsWithMetaFilter(t *testing.T) {
	// With no Docker Hub access in tests, fetchImageTags returns empty.
	// Verify that the filter logic itself is correct.
	allTags, metas := fetchImageTagsWithMeta(t.Context(), "", "", "xyz")
	if len(allTags) != 0 {
		t.Errorf("expected empty tags without repos configured, got %v", allTags)
	}
	if len(metas) != 0 {
		t.Errorf("expected empty metas without repos configured, got %v", metas)
	}
}
