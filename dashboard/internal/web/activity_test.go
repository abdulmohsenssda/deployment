package web

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/abdul-mohsen/deployment/dashboard/internal/config"
	"github.com/abdul-mohsen/deployment/dashboard/internal/dokku"
	"github.com/abdul-mohsen/deployment/dashboard/internal/logbuf"
	"github.com/abdul-mohsen/deployment/dashboard/internal/scripts"
)

func activityTestRouter(t *testing.T, logs *logbuf.Store) http.Handler {
	t.Helper()
	cfg := config.Config{
		EnvName:        "test",
		Listen:         ":0",
		DockerBin:      "docker",
		DokkuContainer: "dokku",
		BaseDomain:     "localhost",
		AdminUser:      "admin",
		AdminHash:      "$2a$10$SBLIFwn9vZCqfa8E7ieIpe5TgN36UKormoYJ3nVFfhZLBkIn5A11K",
		SessionKey:     []byte("testsessionkeyXXXXXXXXXXXXXXXXXX"),
		LogBufferLines: 100,
		TenantStateDir: t.TempDir(),
		BackupDir:      t.TempDir(),
		MySQLHost:      "127.0.0.1",
		MySQLPort:      "3306",
	}
	return Router(cfg, dokku.New(cfg.DockerBin, cfg.DokkuContainer), logs,
		scripts.NewRunner(cfg.DockerBin, cfg.RunnerImage, cfg.ScriptsHostPath, cfg.ConfigFile))
}

func TestAppActivityRequiresAuth(t *testing.T) {
	h := activityTestRouter(t, logbuf.New(10))
	req := httptest.NewRequest(http.MethodGet, "/api/apps/acme-backend/activity", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code < http.StatusMultipleChoices || rr.Code >= http.StatusBadRequest {
		t.Fatalf("expected auth redirect, got %d", rr.Code)
	}
}

func TestAppActivityReturnsEmptyEntries(t *testing.T) {
	h := activityTestRouter(t, logbuf.New(10))
	cookie := authenticate(t, h)
	if cookie == nil {
		t.Fatal("could not obtain session cookie")
	}

	req := httptest.NewRequest(http.MethodGet, "/api/apps/acme-backend/activity", nil)
	req.AddCookie(cookie)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rr.Code, rr.Body.String())
	}
	var body struct {
		Entries []logbuf.Entry `json:"entries"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body.Entries == nil {
		t.Fatal("expected entries to be an empty JSON array, got null")
	}
	if len(body.Entries) != 0 {
		t.Fatalf("got %d entries, want none", len(body.Entries))
	}
}

func TestAppActivityReturnsPersistedEntries(t *testing.T) {
	dir := t.TempDir()
	store, err := logbuf.NewPersistent(10, dir)
	if err != nil {
		t.Fatalf("create persistent store: %v", err)
	}
	if err := store.Append(activityKey("app", "acme-backend"), "OK start acme-backend"); err != nil {
		t.Fatalf("append activity: %v", err)
	}
	reloaded, err := logbuf.NewPersistent(10, dir)
	if err != nil {
		t.Fatalf("reload persistent store: %v", err)
	}

	h := activityTestRouter(t, reloaded)
	cookie := authenticate(t, h)
	if cookie == nil {
		t.Fatal("could not obtain session cookie")
	}
	req := httptest.NewRequest(http.MethodGet, "/api/apps/acme-backend/activity", nil)
	req.AddCookie(cookie)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rr.Code, rr.Body.String())
	}
	var body struct {
		Entries []logbuf.Entry `json:"entries"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(body.Entries) != 1 || body.Entries[0].Line != "OK start acme-backend" {
		t.Fatalf("unexpected entries: %+v", body.Entries)
	}
}

func TestAppActivityRejectsInvalidName(t *testing.T) {
	h := activityTestRouter(t, logbuf.New(10))
	cookie := authenticate(t, h)
	if cookie == nil {
		t.Fatal("could not obtain session cookie")
	}
	req := httptest.NewRequest(http.MethodGet, "/api/apps/not%20an%20app/activity", nil)
	req.AddCookie(cookie)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rr.Code, rr.Body.String())
	}
}

func TestAppPageRendersRecentActivityPanel(t *testing.T) {
	h := activityTestRouter(t, logbuf.New(10))
	cookie := authenticate(t, h)
	if cookie == nil {
		t.Fatal("could not obtain session cookie")
	}
	req := httptest.NewRequest(http.MethodGet, "/apps/acme-backend", nil)
	req.AddCookie(cookie)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rr.Code, rr.Body.String())
	}
	body := rr.Body.String()
	for _, want := range []string{"Recent activity", `id="activity"`, "/api/apps/acme-backend/activity"} {
		if !strings.Contains(body, want) {
			t.Errorf("app page missing %q", want)
		}
	}
}
