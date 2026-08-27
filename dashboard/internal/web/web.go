// Package web wires HTTP routes, auth, and templates for the dashboard.
package web

import (
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"html/template"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/abdul-mohsen/deployment/dashboard/internal/config"
	"github.com/abdul-mohsen/deployment/dashboard/internal/dokku"
	"github.com/abdul-mohsen/deployment/dashboard/internal/logbuf"
	"github.com/abdul-mohsen/deployment/dashboard/internal/retention"
	"github.com/abdul-mohsen/deployment/dashboard/internal/scripts"
	"github.com/abdul-mohsen/deployment/dashboard/internal/tenantstate"
	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/gorilla/sessions"
	"golang.org/x/crypto/bcrypt"
)

//go:embed templates/*.html
var tplFS embed.FS

//go:embed static/*
var staticFS embed.FS

const sessionName = "dashboard"

type server struct {
	cfg         config.Config
	dokku       *dokku.Client
	logs        *logbuf.Store
	runner      *scripts.Runner
	pages       map[string]*template.Template
	store       *sessions.CookieStore
	snapshots   *snapshotCache
	tenantState *tenantstate.Store
	authMu      sync.RWMutex
}

// Router builds the HTTP handler.
func Router(cfg config.Config, d *dokku.Client, l *logbuf.Store, runner *scripts.Runner) http.Handler {
	funcs := template.FuncMap{
		"join":     strings.Join,
		"now":      func() string { return time.Now().Format("2006-01-02 15:04:05") },
		"stateClr": stateClass,
		"httpClr":  httpClass,
		"json":     templateJSON,
	}
	pages := map[string]*template.Template{}
	layoutPages := []string{"index.html", "app.html", "tenant.html", "scripts.html", "script.html", "releases.html", "password.html"}
	for _, name := range layoutPages {
		pages[name] = template.Must(template.New("").Funcs(funcs).ParseFS(tplFS,
			"templates/_layout.html",
			"templates/palette.html",
			"templates/"+name,
		))
	}
	pages["login.html"] = template.Must(template.New("").Funcs(funcs).ParseFS(tplFS, "templates/login.html"))

	store := sessions.NewCookieStore(cfg.SessionKey)
	store.Options = &sessions.Options{
		Path:     "/",
		HttpOnly: true,
		Secure:   cfg.CookieSecure,
		MaxAge:   60 * 60 * 12,
		SameSite: http.SameSiteLaxMode,
	}

	s := &server{cfg: cfg, dokku: d, logs: l, runner: runner, pages: pages, store: store}
	s.tenantState = tenantstate.NewStore(cfg.TenantStateDir)
	s.snapshots = newSnapshotCache(60*time.Second, s.collectSnapshot)
	s.snapshots.Start(context.Background())

	r := chi.NewRouter()
	r.Use(middleware.RequestID)
	r.Use(middleware.RealIP)
	r.Use(middleware.Recoverer)

	staticSub, _ := fs.Sub(staticFS, "static")
	r.Handle("/static/*", http.StripPrefix("/static/", http.FileServer(http.FS(staticSub))))
	r.Get("/healthz", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok")) })

	r.Get("/login", s.handleLoginPage)
	r.Post("/login", s.handleLoginSubmit)
	r.Post("/logout", s.handleLogout)

	r.Group(func(r chi.Router) {
		r.Use(s.requireAuth)
		r.Get("/", s.handleIndex)
		r.Get("/tenants/{name}", s.handleTenant)
		r.Post("/tenants/{name}/{verb}", s.handleTenantAction)
		r.Post("/tenants/{name}/delete", s.handleTenantDelete)
		r.Get("/apps/{name}", s.handleApp)
		r.Post("/apps/{name}/{verb}", s.handleAction)
		r.Get("/apps/{name}/logs", s.handleLogStream)
		r.Get("/apps/{name}/logs.txt", s.handleLogDump)
		r.Get("/api/apps", s.handleAPIApps)
		r.Get("/api/apps/{name}/activity", s.handleAppActivity)
		r.Get("/api/tenants/{name}/activity", s.handleTenantActivity)
		r.Get("/api/scripts/{name}/activity", s.handleScriptActivity)
		r.Get("/api/image-tags", s.handleImageTags)
		r.Get("/events", s.handleEvents)
		r.Get("/settings/password", s.handlePasswordPage)
		r.Post("/settings/password", s.handlePasswordSubmit)
		r.Get("/releases", s.handleReleasesPage)
		r.Get("/scripts", s.handleScriptsPage)
		r.Get("/scripts/{name}", s.handleScriptPage)
		r.Post("/scripts/{name}/run", s.handleScriptRun)
		// Backup & restore endpoints
		r.Post("/tenants/{name}/backup", s.handleTenantBackup)
		r.Get("/tenants/{name}/backups", s.handleTenantBackupList)
		r.Get("/tenants/{name}/backups/{id}/download", s.handleTenantBackupDownload)
		r.Post("/tenants/{name}/backups/{id}/delete", s.handleTenantBackupDelete)
		r.Post("/tenants/{name}/backups/{id}/restore", s.handleTenantRestore)
		r.Get("/tenants/{name}/accounting-export", s.handleAccountingExport)
		// Auto-redeploy toggle
		r.Post("/tenants/{name}/auto-redeploy", s.handleTenantAutoRedeploy)
		// Credential management
		r.Get("/tenants/{name}/credentials", s.handleTenantCredentials)
		r.Post("/tenants/{name}/credentials", s.handleTenantUpdateCredentials)
	})

	return r
}

func templateJSON(v any) template.JS {
	b, err := json.Marshal(v)
	if err != nil {
		return template.JS("null")
	}
	return template.JS(b)
}

// ---- Auth -------------------------------------------------------------------

func (s *server) requireAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sess, _ := s.store.Get(r, sessionName)
		if v, ok := sess.Values["user"].(string); !ok || v == "" {
			if r.URL.Query().Get("from") == "login" {
				http.Redirect(w, r, "/login?e=session", http.StatusSeeOther)
				return
			}
			http.Redirect(w, r, "/login", http.StatusSeeOther)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *server) handleLoginPage(w http.ResponseWriter, r *http.Request) {
	s.render(w, "login.html", map[string]any{"Env": s.cfg.EnvName, "Error": r.URL.Query().Get("e")})
}

func (s *server) handleLoginSubmit(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad form", http.StatusBadRequest)
		return
	}
	user := strings.TrimSpace(r.FormValue("user"))
	pass := strings.TrimSpace(r.FormValue("pass"))
	if user != s.cfg.AdminUser || !s.passwordMatches(pass) {
		http.Redirect(w, r, "/login?e=invalid", http.StatusSeeOther)
		return
	}
	sess, _ := s.store.Get(r, sessionName)
	sess.Values["user"] = user
	if err := sess.Save(r, w); err != nil {
		http.Redirect(w, r, "/login?e=session", http.StatusSeeOther)
		return
	}
	http.Redirect(w, r, "/?from=login", http.StatusSeeOther)
}

func (s *server) handlePasswordPage(w http.ResponseWriter, r *http.Request) {
	s.render(w, "password.html", map[string]any{
		"Env":     s.cfg.EnvName,
		"Saved":   r.URL.Query().Get("saved") == "1",
		"Error":   r.URL.Query().Get("e"),
		"CanSave": strings.TrimSpace(s.cfg.DashboardEnvFile) != "",
		"EnvFile": s.cfg.DashboardEnvFile,
	})
}

func (s *server) handlePasswordSubmit(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad form", http.StatusBadRequest)
		return
	}
	current := r.FormValue("current_password")
	newPassword := r.FormValue("new_password")
	confirm := r.FormValue("confirm_password")
	if !s.passwordMatches(current) {
		http.Redirect(w, r, "/settings/password?e=current", http.StatusSeeOther)
		return
	}
	if len(newPassword) < 8 {
		http.Redirect(w, r, "/settings/password?e=short", http.StatusSeeOther)
		return
	}
	if newPassword != confirm {
		http.Redirect(w, r, "/settings/password?e=match", http.StatusSeeOther)
		return
	}
	if strings.TrimSpace(s.cfg.DashboardEnvFile) == "" {
		http.Redirect(w, r, "/settings/password?e=envfile", http.StatusSeeOther)
		return
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(newPassword), 10)
	if err != nil {
		http.Error(w, "failed to hash password", http.StatusInternalServerError)
		return
	}
	if err := config.UpdateEnvFileValue(s.cfg.DashboardEnvFile, "ADMIN_PASSWORD_HASH", string(hash)); err != nil {
		http.Error(w, "failed to update dashboard env file: "+err.Error(), http.StatusInternalServerError)
		return
	}
	s.setPasswordHash(string(hash))
	_ = os.Setenv("ADMIN_PASSWORD_HASH", string(hash))
	http.Redirect(w, r, "/settings/password?saved=1", http.StatusSeeOther)
}

func (s *server) passwordMatches(password string) bool {
	s.authMu.RLock()
	hash := s.cfg.AdminHash
	s.authMu.RUnlock()
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(password)) == nil
}

func (s *server) setPasswordHash(hash string) {
	s.authMu.Lock()
	s.cfg.AdminHash = hash
	s.authMu.Unlock()
}

func (s *server) handleLogout(w http.ResponseWriter, r *http.Request) {
	sess, _ := s.store.Get(r, sessionName)
	delete(sess.Values, "user")
	sess.Options.MaxAge = -1
	_ = sess.Save(r, w)
	http.Redirect(w, r, "/login", http.StatusSeeOther)
}

// ---- Pages ------------------------------------------------------------------

func (s *server) handleIndex(w http.ResponseWriter, r *http.Request) {
	snap, _ := s.snapshots.Snapshot()
	data := map[string]any{
		"Env":        s.cfg.EnvName,
		"Base":       s.cfg.BaseDomain,
		"Apps":       snap.Apps,
		"Healthy":    snap.Healthy,
		"UpdatedAt":  snap.UpdatedAt,
		"Refreshing": snap.Refreshing,
	}
	if r.Header.Get("HX-Request") == "true" {
		s.renderPartial(w, "apps_table.html", data)
		return
	}
	s.render(w, "index.html", data)
}

func (s *server) handleApp(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	if !validAppName(name) {
		http.Error(w, "invalid name", http.StatusBadRequest)
		return
	}
	app := s.dokku.AppDetails(r.Context(), name)
	s.render(w, "app.html", map[string]any{
		"Env":  s.cfg.EnvName,
		"Base": s.cfg.BaseDomain,
		"App":  app,
	})
}

func (s *server) handleTenant(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	if !validAppName(name) {
		http.Error(w, "invalid name", http.StatusBadRequest)
		return
	}
	apps := s.appsForTenant(r.Context(), name)
	if len(apps) == 0 {
		http.NotFound(w, r)
		return
	}
	for i := range apps {
		apps[i] = s.dokku.AppDetails(r.Context(), apps[i].Name)
	}
	var backend, frontend *dokku.App
	for i := range apps {
		switch apps[i].Role {
		case "backend":
			backend = &apps[i]
		case "frontend":
			frontend = &apps[i]
		}
	}
	autoRedeploy := s.tenantState.IsAutoRedeployEnabled(name)
	s.render(w, "tenant.html", map[string]any{
		"Env":                 s.cfg.EnvName,
		"Base":                s.cfg.BaseDomain,
		"Tenant":              name,
		"Apps":                apps,
		"Backend":             backend,
		"Frontend":            frontend,
		"Versions":            scripts.VersionCatalog(),
		"DefaultVersion":      tenantSyncVersion(backend, frontend, scripts.DefaultImageVersion()),
		"AutoRedeploy":        autoRedeploy,
		"BackupRetentionDays": backupRetentionDays(s.cfg.BackupRetentionDays),
		"MaxUserBackups":      50,
	})
}

func backupRetentionDays(days int) int {
	if days <= 0 {
		return retention.DefaultRetentionDays
	}
	return days
}

// tenantSyncVersion returns the image tag to pre-fill the Sync-version form
// with. It prefers the tenant's currently deployed tag (backend first, then
// frontend) so the details reflect the selected/deployed version instead of the
// fleet default. When neither app reports a version it falls back to def.
func tenantSyncVersion(backend, frontend *dokku.App, def string) string {
	if backend != nil {
		if v := strings.TrimSpace(backend.Version); v != "" {
			return v
		}
	}
	if frontend != nil {
		if v := strings.TrimSpace(frontend.Version); v != "" {
			return v
		}
	}
	return def
}

func (s *server) handleTenantAction(w http.ResponseWriter, r *http.Request) {
	tenant := chi.URLParam(r, "name")
	verb := chi.URLParam(r, "verb")
	if !validAppName(tenant) {
		http.Error(w, "invalid name", http.StatusBadRequest)
		return
	}
	if verb != "start" && verb != "stop" && verb != "restart" && verb != "rebuild" {
		http.Error(w, "invalid action", http.StatusBadRequest)
		return
	}
	apps := s.appsForTenant(r.Context(), tenant)
	if len(apps) == 0 {
		http.NotFound(w, r)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Minute)
	defer cancel()
	activity := activityKey("tenant", tenant)
	s.recordActivity(activity, fmt.Sprintf("--- %s %s @ %s ---", verb, tenant, time.Now().UTC().Format(time.RFC3339)))
	failed := false
	var body strings.Builder
	for _, app := range apps {
		out, err := s.dokku.Action(ctx, app.Name, verb)
		if err != nil {
			failed = true
			s.recordActivity(activity, fmt.Sprintf("FAILED %s %s", verb, app.Name))
			s.recordActivityBlock(activity, out)
			s.recordActivity(activity, err.Error())
			fmt.Fprintf(&body, "FAILED %s %s\n%s\n%v\n", verb, app.Name, out, err)
			continue
		}
		s.recordActivity(activity, fmt.Sprintf("OK %s %s", verb, app.Name))
		s.recordActivityBlock(activity, out)
		fmt.Fprintf(&body, "OK %s %s\n%s\n", verb, app.Name, out)
	}
	if failed {
		s.recordActivity(activity, "--- action failed ---")
	} else {
		s.recordActivity(activity, "--- action complete ---")
	}
	s.snapshots.RefreshSoon()
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	if failed {
		w.WriteHeader(http.StatusBadGateway)
	}
	fmt.Fprint(w, body.String())
}

// handleTenantDelete tears down a tenant end-to-end via remove-tenant.sh.
// Requires POST form field confirm=<tenant> (server-side type-to-confirm)
// so an accidental navigation cannot destroy data. Streams the script's
// output as SSE so the operator sees each step.
func (s *server) handleTenantDelete(w http.ResponseWriter, r *http.Request) {
	tenant := chi.URLParam(r, "name")
	if !validAppName(tenant) {
		http.Error(w, "invalid name", http.StatusBadRequest)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad form", http.StatusBadRequest)
		return
	}
	if r.FormValue("confirm") != tenant {
		http.Error(w, "confirmation mismatch: POST confirm=<tenant> required", http.StatusBadRequest)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Minute)
	defer cancel()

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	fmt.Fprintf(w, "data: Deleting tenant %s (apps + DB + storage + backups)...\n\n", tenant)
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}

	// remove-tenant.sh <name> --force  (full cleanup is the default since #115)
	argv := []string{tenant, "--force"}
	activity := activityKey("tenant", tenant)
	s.recordActivity(activity, fmt.Sprintf("--- delete %s @ %s ---", tenant, time.Now().UTC().Format(time.RFC3339)))
	runErr := s.runner.RunWithCallback(ctx, w, "remove-tenant.sh", argv, func(line string) {
		s.recordActivity(activity, line)
	})
	if runErr != nil {
		s.recordActivity(activity, "ERROR: "+runErr.Error())
		fmt.Fprintf(w, "event: error\ndata: %s\n\n", runErr.Error())
		s.recordActivity(activity, "--- delete failed ---")
	} else {
		s.recordActivity(activity, "--- delete complete ---")
	}
	s.snapshots.RefreshSoon()
	fmt.Fprint(w, "event: done\ndata: end\n\n")
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}
}

func (s *server) handleAction(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	verb := chi.URLParam(r, "verb")
	if !validAppName(name) {
		http.Error(w, "invalid name", http.StatusBadRequest)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()
	activity := activityKey("app", name)
	s.recordActivity(activity, fmt.Sprintf("--- %s %s @ %s ---", verb, name, time.Now().UTC().Format(time.RFC3339)))
	out, err := s.dokku.Action(ctx, name, verb)
	if err != nil {
		s.recordActivity(activity, fmt.Sprintf("FAILED %s %s", verb, name))
		s.recordActivityBlock(activity, out)
		s.recordActivity(activity, err.Error())
	} else {
		s.recordActivity(activity, fmt.Sprintf("OK %s %s", verb, name))
		s.recordActivityBlock(activity, out)
	}
	if err != nil {
		s.recordActivity(activity, "--- action failed ---")
	} else {
		s.recordActivity(activity, "--- action complete ---")
	}
	s.snapshots.RefreshSoon()
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	if err != nil {
		w.WriteHeader(http.StatusBadGateway)
		fmt.Fprintf(w, "FAILED %s %s\n%s\n%v\n", verb, name, out, err)
		return
	}
	fmt.Fprintf(w, "OK %s %s\n%s", verb, name, out)
}

func (s *server) handleLogStream(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	if !validAppName(name) {
		http.Error(w, "invalid name", http.StatusBadRequest)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	for _, e := range s.logs.Snapshot(name) {
		fmt.Fprintf(w, "data: %s %s\n\n", e.At.UTC().Format(time.RFC3339), e.Line)
	}
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}

	_ = s.dokku.StreamLogs(r.Context(), name, w, func(line string) {
		s.recordLog(name, line)
	})
}

func (s *server) handleLogDump(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	if !validAppName(name) {
		http.Error(w, "invalid name", http.StatusBadRequest)
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s.log"`, name))
	_, _ = w.Write([]byte(s.logs.Dump(name)))
}

func (s *server) handleAPIApps(w http.ResponseWriter, r *http.Request) {
	snap, _ := s.snapshots.Snapshot()
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprint(w, appsJSON(snap.Apps))
}

// handleImageTags returns available image tags from Docker Hub for autocomplete.
// Optional ?q=<substr> filters results to tags whose name contains the substring.
// Each tag entry includes metadata (is_branch, digest, last_pushed) for branch-name tags.
func (s *server) handleImageTags(w http.ResponseWriter, r *http.Request) {
	backendRepo := strings.TrimSpace(os.Getenv("BACKEND_IMAGE"))
	frontendRepo := strings.TrimSpace(os.Getenv("FRONTEND_IMAGE"))
	if backendRepo == "" {
		if u := strings.TrimSpace(os.Getenv("DOCKERHUB_USERNAME")); u != "" {
			backendRepo = u + "/ifritah-api"
		}
	}
	if frontendRepo == "" {
		if u := strings.TrimSpace(os.Getenv("DOCKERHUB_USERNAME")); u != "" {
			frontendRepo = u + "/ifritah-web"
		}
	}

	query := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("q")))
	tags, metas := fetchImageTagsWithMeta(r.Context(), backendRepo, frontendRepo, query)

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "max-age=60")
	_ = json.NewEncoder(w).Encode(map[string]any{"tags": tags, "meta": metas})
}

// TagMeta holds per-tag metadata returned alongside the tag list.
type TagMeta struct {
	Tag          string `json:"tag"`
	LastPushed   string `json:"last_pushed,omitempty"`   // ISO8601
	Digest       string `json:"digest,omitempty"`        // first 19 chars of "sha256:..."
	IsBranch     bool   `json:"is_branch"`               // true when not a semver vX.Y.Z tag
	InBoth       bool   `json:"in_both"`                 // true when tag exists in both backend AND frontend repos
	BackendOnly  bool   `json:"backend_only,omitempty"`  // true when only in backend repo
	FrontendOnly bool   `json:"frontend_only,omitempty"` // true when only in frontend repo
}

// fetchImageTagsWithMeta returns the filtered tag list + per-tag metadata including
// whether each tag is available in both repos (safe to deploy) or only one (partial).
func fetchImageTagsWithMeta(ctx context.Context, backendRepo, frontendRepo, query string) ([]string, []TagMeta) {
	// Fetch tag sets from both repos to compute coverage
	bTagSet, fTagSet := fetchImageTagSets(ctx, backendRepo, frontendRepo)

	// Build union sorted list (same logic as fetchImageTags but we already have the sets)
	allTagsMap := map[string]bool{}
	for t := range bTagSet {
		allTagsMap[t] = true
	}
	for t := range fTagSet {
		allTagsMap[t] = true
	}

	priority := func(tag string) int {
		switch tag {
		case "dev":
			return 0
		case "latest":
			return 1
		}
		if scripts.IsImageVersionTag(tag) {
			return 2
		}
		return 3
	}
	both := func(t string) bool { return bTagSet[t] && fTagSet[t] }

	allTags := make([]string, 0, len(allTagsMap))
	for t := range allTagsMap {
		allTags = append(allTags, t)
	}
	sort.Slice(allTags, func(i, j int) bool {
		pi, pj := priority(allTags[i]), priority(allTags[j])
		if pi != pj {
			return pi < pj
		}
		bi, bj := both(allTags[i]), both(allTags[j])
		if bi != bj {
			return bi
		}
		return allTags[i] > allTags[j]
	})

	// Apply substring filter
	if query != "" {
		filtered := allTags[:0]
		for _, t := range allTags {
			if strings.Contains(strings.ToLower(t), query) {
				filtered = append(filtered, t)
			}
		}
		allTags = filtered
	}

	// Fetch metadata for branch-name tags, limit 20 to avoid latency
	repo := backendRepo
	if repo == "" {
		repo = frontendRepo
	}
	metas := make([]TagMeta, 0, len(allTags))
	fetched := 0
	for _, tag := range allTags {
		m := TagMeta{Tag: tag}
		m.IsBranch = !scripts.IsImageVersionTag(tag) && tag != "latest" && tag != "dev"
		m.InBoth = bTagSet[tag] && fTagSet[tag]
		m.BackendOnly = bTagSet[tag] && !fTagSet[tag]
		m.FrontendOnly = !bTagSet[tag] && fTagSet[tag]
		if m.IsBranch && repo != "" && fetched < 20 {
			m.LastPushed, m.Digest = fetchSingleTagMeta(ctx, repo, tag)
			fetched++
		}
		metas = append(metas, m)
	}
	return allTags, metas
}

// fetchImageTagSets returns the raw tag sets for both repos separately.
func fetchImageTagSets(ctx context.Context, backendRepo, frontendRepo string) (bTags, fTags map[string]bool) {
	fetch := func(repo string) map[string]bool {
		set := map[string]bool{}
		if repo == "" {
			return set
		}
		page := "https://hub.docker.com/v2/repositories/" + repo + "/tags?page_size=100&ordering=last_updated"
		for i := 0; i < 5 && page != ""; i++ {
			req, err := http.NewRequestWithContext(ctx, http.MethodGet, page, nil)
			if err != nil {
				break
			}
			resp, err := http.DefaultClient.Do(req)
			if err != nil || resp.StatusCode != http.StatusOK {
				if resp != nil {
					resp.Body.Close()
				}
				break
			}
			var result struct {
				Next    string `json:"next"`
				Results []struct {
					Name string `json:"name"`
				} `json:"results"`
			}
			_ = json.NewDecoder(resp.Body).Decode(&result)
			resp.Body.Close()
			for _, r := range result.Results {
				if r.Name != "" {
					set[r.Name] = true
				}
			}
			page = result.Next
		}
		return set
	}
	return fetch(backendRepo), fetch(frontendRepo)
}

// fetchSingleTagMeta calls the Docker Hub v2 tag detail API and returns
// (lastPushed RFC3339, shortDigest). Returns empty strings on any error.
func fetchSingleTagMeta(ctx context.Context, repo, tag string) (lastPushed, digest string) {
	apiURL := "https://hub.docker.com/v2/repositories/" + repo + "/tags/" + tag
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, apiURL, nil)
	if err != nil {
		return
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil || resp.StatusCode != http.StatusOK {
		if resp != nil {
			resp.Body.Close()
		}
		return
	}
	defer resp.Body.Close()
	var result struct {
		LastUpdated string `json:"last_updated"`
		Images      []struct {
			Digest string `json:"digest"`
		} `json:"images"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return
	}
	lastPushed = result.LastUpdated
	if len(result.Images) > 0 {
		d := result.Images[0].Digest
		if len(d) > 19 {
			digest = d[:19] // "sha256:" (7 chars) + 12 hex chars
		} else {
			digest = d
		}
	}
	return
}

// fetchImageTags queries Docker Hub for tags from both repos and returns a
// sorted, deduplicated list. Delegates to fetchImageTagSets to avoid code duplication.
func fetchImageTags(ctx context.Context, backendRepo, frontendRepo string) []string {
	if backendRepo == "" && frontendRepo == "" {
		return []string{}
	}
	bTags, fTags := fetchImageTagSets(ctx, backendRepo, frontendRepo)

	both := map[string]bool{}
	all := map[string]bool{}
	for t := range bTags {
		all[t] = true
		if fTags[t] {
			both[t] = true
		}
	}
	for t := range fTags {
		all[t] = true
	}

	// Priority order: dev and latest first, then semver (newest first), then branches, then rest
	priority := func(tag string) int {
		switch tag {
		case "dev":
			return 0
		case "latest":
			return 1
		}
		if scripts.IsImageVersionTag(tag) {
			return 2
		}
		return 3
	}

	tags := make([]string, 0, len(all))
	for t := range all {
		tags = append(tags, t)
	}
	sort.Slice(tags, func(i, j int) bool {
		pi, pj := priority(tags[i]), priority(tags[j])
		if pi != pj {
			return pi < pj
		}
		// Within same priority: tags in both repos first, then reverse-alpha (newest semver first)
		bi, bj := both[tags[i]], both[tags[j]]
		if bi != bj {
			return bi
		}
		return tags[i] > tags[j] // reverse alpha = newer semver / newer branch names first
	})
	return tags
}

// handleEvents pushes cached snapshots as the background collector refreshes.
func (s *server) handleEvents(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	flusher, _ := w.(http.Flusher)

	push := func(snap appSnapshot) bool {
		if _, err := fmt.Fprintf(w, "event: snapshot\ndata: %s\n\n", snapshotJSON(snap)); err != nil {
			return false
		}
		if flusher != nil {
			flusher.Flush()
		}
		return true
	}

	snap, seq := s.snapshots.Snapshot()
	if !push(snap) {
		return
	}
	for {
		next, nextSeq, ok := s.snapshots.Wait(r.Context(), seq)
		if !ok {
			return
		}
		seq = nextSeq
		if !push(next) {
			return
		}
	}
}

// ---- Helpers ----------------------------------------------------------------

func (s *server) handleScriptsPage(w http.ResponseWriter, _ *http.Request) {
	s.render(w, "scripts.html", map[string]any{
		"Env":      s.cfg.EnvName,
		"Scripts":  scripts.Catalog(),
		"Releases": s.releaseViews(),
	})
}

func (s *server) handleReleasesPage(w http.ResponseWriter, _ *http.Request) {
	s.render(w, "releases.html", map[string]any{
		"Env":            s.cfg.EnvName,
		"Releases":       s.releaseViews(),
		"DefaultVersion": scripts.DefaultImageVersion(),
	})
}

type releaseView struct {
	scripts.ImageVersion
	Deployed       int
	Failed         int
	FailureSummary string
}

func (s *server) releaseViews() []releaseView {
	snap, _ := s.snapshots.Snapshot()
	return buildReleaseViews(scripts.ReleaseCatalog(), snap.Apps)
}

func buildReleaseViews(catalog []scripts.ImageVersion, apps []dokku.App) []releaseView {
	byTag := map[string]*releaseView{}
	order := []string{}
	add := func(release scripts.ImageVersion) *releaseView {
		tag := strings.TrimSpace(release.Tag)
		if !scripts.IsImageVersionTag(tag) {
			return nil
		}
		if existing := byTag[tag]; existing != nil {
			return existing
		}
		if release.Status == "" {
			release.Status = "ready"
		}
		if release.Title == "" {
			release.Title = tag
		}
		view := &releaseView{ImageVersion: release}
		byTag[tag] = view
		order = append(order, tag)
		return view
	}
	for _, release := range catalog {
		add(release)
	}
	for _, app := range apps {
		tag := strings.TrimSpace(app.Version)
		if !scripts.IsImageVersionTag(tag) {
			continue
		}
		view := byTag[tag]
		if view == nil {
			view = add(scripts.ImageVersion{Tag: tag, Status: "deployed", Title: tag})
		}
		if view == nil {
			continue
		}
		view.Deployed++
		switch app.Role {
		case "backend":
			if view.BackendImage == "" {
				view.BackendImage = app.Image
			}
		case "frontend":
			if view.FrontendImage == "" {
				view.FrontendImage = app.Image
			}
		}
		if app.State != "" && app.State != "running" {
			view.Failed++
			if view.FailureSummary == "" {
				view.FailureSummary = app.Name + " is " + app.State
			}
		}
	}
	views := make([]releaseView, 0, len(order))
	for _, tag := range order {
		view := *byTag[tag]
		if view.Failed > 0 {
			view.Broken = true
			view.Status = "broken"
			if view.FailureSummary == "" {
				view.FailureSummary = fmt.Sprintf("%d of %d deployed apps failed", view.Failed, view.Deployed)
			}
		}
		views = append(views, view)
	}
	return views
}

func (s *server) handleScriptPage(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	sc := scripts.Find(name)
	if sc == nil {
		http.NotFound(w, r)
		return
	}
	s.render(w, "script.html", map[string]any{
		"Env":              s.cfg.EnvName,
		"Script":           sc,
		"Releases":         s.releaseViews(),
		"RunnerConfigured": s.cfg.ScriptsHostPath != "",
	})
}

// handleScriptRun takes form values, builds an argv, and streams the script's
// output back as SSE. Inputs are validated against the script's field schema
// and the strict character allow-list in the runner package.
func (s *server) handleScriptRun(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	sc := scripts.Find(name)
	if sc == nil {
		http.NotFound(w, r)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	argv, err := buildArgv(sc, r.PostForm)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	fmt.Fprintf(w, "data: $ bash scripts/deployctl.sh %s %s\n\n", sc.ControlCommand(), strings.Join(displayArgv(sc, argv), " "))
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}

	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Minute)
	defer cancel()
	activityKeys := scriptActivityKeys(sc, r.PostForm)
	command := "$ bash scripts/deployctl.sh " + sc.ControlCommand() + " " + strings.Join(displayArgv(sc, argv), " ")
	s.recordActivities(activityKeys, fmt.Sprintf("--- run %s @ %s ---", sc.Slug(), time.Now().UTC().Format(time.RFC3339)))
	s.recordActivities(activityKeys, command)
	runErr := s.runner.RunWithCallback(ctx, w, sc.Name, argv, func(line string) {
		s.recordActivities(activityKeys, line)
	})
	if runErr != nil {
		s.recordActivities(activityKeys, "ERROR: "+runErr.Error())
		fmt.Fprintf(w, "event: error\ndata: %s\n\n", runErr.Error())
		s.recordActivities(activityKeys, "--- run failed ---")
	} else {
		s.recordActivities(activityKeys, "--- run complete ---")
	}
	fmt.Fprint(w, "event: done\ndata: end\n\n")
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}
}

// buildArgv translates a posted form into the script's argv list. Positional
// fields (Name starts with "_pos_") are emitted first in declaration order;
// flag fields follow. KV ("key=value" lines) become repeated --flag pairs.
// Special: fields with Flag:"--env" are formatted as KEY=VALUE pairs.
func buildArgv(sc *scripts.Script, form url.Values) ([]string, error) {
	form, err := expandImageVersion(sc, form)
	if err != nil {
		return nil, err
	}
	var positionals, flags []string
	for _, f := range sc.Fields {
		v := strings.TrimSpace(form.Get(f.Name))
		if f.Boolean {
			if form.Get(f.Name) != "" {
				flags = append(flags, f.Flag)
			}
			continue
		}
		if v == "" && f.Default != "" {
			v = f.Default
		}
		if v == "" {
			if f.Required {
				return nil, fmt.Errorf("%s is required", f.Label)
			}
			continue
		}
		switch f.Type {
		case "kv":
			for _, ln := range strings.Split(v, "\n") {
				ln = strings.TrimSpace(ln)
				if ln == "" {
					continue
				}
				if !strings.Contains(ln, "=") {
					return nil, fmt.Errorf("%s line %q must be KEY=VALUE", f.Label, ln)
				}
				flags = append(flags, f.Flag, ln)
			}
		default:
			if strings.HasPrefix(f.Name, "_pos_") {
				positionals = append(positionals, v)
			} else if f.Flag == "" {
				continue
			} else if f.Flag == "--env" {
				// Convert field name to uppercase env var name (admin_user -> ADMIN_USER)
				envKey := strings.ToUpper(f.Name)
				flags = append(flags, f.Flag, envKey+"="+v)
			} else {
				flags = append(flags, f.Flag, v)
			}
		}
	}
	// Cross-field validation: if a manager username is supplied, demand a password too.
	if mu := strings.TrimSpace(form.Get("manager_user")); mu != "" {
		if strings.TrimSpace(form.Get("manager_password")) == "" {
			return nil, fmt.Errorf("Manager password is required when a Manager username is set")
		}
	}
	return append(positionals, flags...), nil
}

func expandImageVersion(sc *scripts.Script, form url.Values) (url.Values, error) {
	version := strings.TrimSpace(form.Get("image_version"))
	if version == "" {
		version = defaultFieldValue(sc, "image_version")
	}
	if version == "" {
		return form, nil
	}

	// First try the semver catalog (vX.Y.Z tags with pinned image names).
	resolved, ok := scripts.ResolveImageVersion(version)
	if !ok {
		// Not a semver catalog tag — treat as a raw Docker tag (dev, latest, branch name, sha).
		// Build image names directly from the configured repos + the supplied tag.
		backendRepo := scripts.BackendRepo()
		frontendRepo := scripts.FrontendRepo()
		if backendRepo == "" && frontendRepo == "" {
			return nil, fmt.Errorf("image tag %q is not in the release catalog and DOCKERHUB_USERNAME / BACKEND_IMAGE / FRONTEND_IMAGE are not configured", version)
		}
		resolved = scripts.ImageVersion{
			Tag:           version,
			BackendImage:  backendRepo + ":" + version,
			FrontendImage: frontendRepo + ":" + version,
		}
	}

	out := cloneValues(form)
	if scriptHasField(sc, "backend_image") && strings.TrimSpace(out.Get("backend_image")) == "" {
		out.Set("backend_image", resolved.BackendImage)
	}
	if scriptHasField(sc, "frontend_image") && strings.TrimSpace(out.Get("frontend_image")) == "" {
		out.Set("frontend_image", resolved.FrontendImage)
	}
	if scriptHasField(sc, "backend") && strings.TrimSpace(out.Get("backend")) == "" {
		out.Set("backend", resolved.BackendImage)
	}
	if scriptHasField(sc, "frontend") && strings.TrimSpace(out.Get("frontend")) == "" {
		out.Set("frontend", resolved.FrontendImage)
	}
	if scriptHasField(sc, "_pos_image") && strings.TrimSpace(out.Get("_pos_image")) == "" {
		image := resolved.BackendImage
		if strings.TrimSpace(out.Get("type")) == "frontend" {
			image = resolved.FrontendImage
		}
		out.Set("_pos_image", image)
	}
	if scriptHasField(sc, "to") && strings.TrimSpace(out.Get("to")) == "" {
		image := resolved.BackendImage
		if strings.TrimSpace(out.Get("type")) == "frontend" {
			image = resolved.FrontendImage
		}
		out.Set("to", image)
	}
	return out, nil
}

func defaultFieldValue(sc *scripts.Script, name string) string {
	for _, f := range sc.Fields {
		if f.Name == name {
			return strings.TrimSpace(f.Default)
		}
	}
	return ""
}

func scriptHasField(sc *scripts.Script, name string) bool {
	for _, f := range sc.Fields {
		if f.Name == name {
			return true
		}
	}
	return false
}

func cloneValues(in url.Values) url.Values {
	out := make(url.Values, len(in))
	for k, v := range in {
		vv := make([]string, len(v))
		copy(vv, v)
		out[k] = vv
	}
	return out
}

// displayArgv returns argv with values of secret fields replaced by ***
// for safe echoing in the streamed command line.
func displayArgv(sc *scripts.Script, argv []string) []string {
	secretEnv := map[string]bool{}
	for _, f := range sc.Fields {
		if f.Secret && f.Flag == "--env" {
			secretEnv[strings.ToUpper(f.Name)+"="] = true
		}
	}
	if len(secretEnv) == 0 {
		return argv
	}
	out := make([]string, len(argv))
	copy(out, argv)
	for i, a := range out {
		for prefix := range secretEnv {
			if strings.HasPrefix(a, prefix) {
				out[i] = prefix + "***"
				break
			}
		}
	}
	return out
}

// handleTenantAutoRedeploy persists the auto-redeploy toggle for a tenant.
// POST /tenants/{name}/auto-redeploy  with form field enabled=1|0
func (s *server) handleTenantAutoRedeploy(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	if !validAppName(name) {
		http.Error(w, "invalid name", http.StatusBadRequest)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad form", http.StatusBadRequest)
		return
	}
	enabled := r.FormValue("enabled") == "1"
	if err := s.tenantState.SetAutoRedeploy(name, enabled); err != nil {
		http.Error(w, "failed to save setting: "+err.Error(), http.StatusInternalServerError)
		return
	}
	state := "disabled"
	if enabled {
		state = "enabled"
	}
	s.recordActivity(activityKey("tenant", name), fmt.Sprintf("Auto-redeploy %s @ %s", state, time.Now().UTC().Format(time.RFC3339)))
	w.WriteHeader(http.StatusNoContent)
}

// handleTenantCredentials returns the admin/manager usernames stored in Dokku config.
// GET /tenants/{name}/credentials
func (s *server) handleTenantCredentials(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	if !validAppName(name) {
		http.Error(w, "invalid name", http.StatusBadRequest)
		return
	}
	backendApp := name + "-backend"
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	adminUser, _ := s.dokku.ConfigGet(ctx, backendApp, "ADMIN_USER")
	managerUser, _ := s.dokku.ConfigGet(ctx, backendApp, "MANAGER_USER")

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"admin_user":   adminUser,
		"manager_user": managerUser,
	})
}

// handleTenantUpdateCredentials updates admin/manager passwords in Dokku config
// and reseeds them via the backend's /api/v2 register/update endpoints.
// POST /tenants/{name}/credentials
// Form fields: role (admin|manager), new_password
func (s *server) handleTenantUpdateCredentials(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	if !validAppName(name) {
		http.Error(w, "invalid name", http.StatusBadRequest)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad form", http.StatusBadRequest)
		return
	}

	role := strings.TrimSpace(r.FormValue("role"))
	newPassword := strings.TrimSpace(r.FormValue("new_password"))

	if role != "admin" && role != "manager" {
		http.Error(w, "role must be admin or manager", http.StatusBadRequest)
		return
	}
	if len(newPassword) < 8 {
		http.Error(w, "password must be at least 8 characters", http.StatusBadRequest)
		return
	}

	backendApp := name + "-backend"
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()

	// 1. Update the password in Dokku config (for future reseeds)
	envKey := "ADMIN_PASSWORD"
	userKey := "ADMIN_USER"
	if role == "manager" {
		envKey = "MANAGER_PASSWORD"
		userKey = "MANAGER_USER"
	}
	username, _ := s.dokku.ConfigGet(ctx, backendApp, userKey)
	if err := s.dokku.ConfigSet(ctx, backendApp, map[string]string{envKey: newPassword}); err != nil {
		s.recordActivity(activityKey("tenant", name), fmt.Sprintf("Failed to update %s password in Dokku config: %v", role, err))
		http.Error(w, "failed to update Dokku config: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// 2. Update the password in MySQL directly (fastest path, no API call needed)
	dbName := "tenant_" + strings.ReplaceAll(name, "-", "_")
	host := s.cfg.MySQLHost
	port := s.cfg.MySQLPort
	user := strings.TrimSpace(os.Getenv("MYSQL_ROOT_USER"))
	if user == "" {
		user = "root"
	}
	password := os.Getenv("MYSQL_ROOT_PASSWORD")

	// Use the backend API instead — it handles bcrypt hashing
	// Find the backend's internal URL from Dokku
	backendURL := "http://" + backendApp + ".web:8090"
	_ = dbName // used for direct MySQL fallback only

	// Call the backend's admin password reset endpoint
	// POST /api/v2/user/:id/password requires admin JWT — instead use MySQL directly
	dsn := fmt.Sprintf("%s:%s@tcp(%s:%s)/%s?timeout=10s", user, password, host, port, dbName)
	if err := updateUserPasswordMySQL(ctx, dsn, username, newPassword); err != nil {
		// Log but don't fail — Dokku config was already updated
		_ = backendURL
		s.recordActivity(activityKey("tenant", name), fmt.Sprintf("Dokku config updated; MySQL %s password update failed: %v", role, err))
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"ok":      false,
			"warning": "Dokku config updated but MySQL password update failed: " + err.Error(),
		})
		return
	}

	s.recordActivity(activityKey("tenant", name), fmt.Sprintf("Password changed for %s (%s)", role, username))
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"ok":      true,
		"message": "Password updated for " + role + " (" + username + ")",
	})
}

func (s *server) collectSnapshot(ctx context.Context) appSnapshot {
	names, err := s.dokku.AppsList(ctx)
	names = s.filterAppNames(names)
	containerIDs := s.dokku.ContainerIDsByApp(ctx)
	domains := s.dokku.DomainMap(ctx)
	detail := func(ctx context.Context, name string) dokku.App {
		return s.dokku.AppSummaryFrom(ctx, name, containerIDs[name], domains[name])
	}
	out := collectAppDetails(ctx, names, snapshotWorkerLimit(len(names)), detail)
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	snap := appSnapshot{
		Apps:    out,
		Healthy: s.dokku.DokkuContainerHealthy(ctx),
	}
	if err != nil {
		snap.Error = err.Error()
	}
	return snap
}

func collectAppDetails(ctx context.Context, names []string, workerLimit int, detail func(context.Context, string) dokku.App) []dokku.App {
	if len(names) == 0 {
		return nil
	}
	if workerLimit < 1 {
		workerLimit = 1
	}
	if workerLimit > len(names) {
		workerLimit = len(names)
	}

	jobs := make(chan string)
	results := make(chan dokku.App, len(names))
	var workers sync.WaitGroup

	for workerIndex := 0; workerIndex < workerLimit; workerIndex++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for appName := range jobs {
				select {
				case <-ctx.Done():
					return
				default:
				}
				app := detail(ctx, appName)
				select {
				case results <- app:
				case <-ctx.Done():
					return
				}
			}
		}()
	}

	go func() {
		defer close(jobs)
		for _, appName := range names {
			select {
			case jobs <- appName:
			case <-ctx.Done():
				return
			}
		}
	}()

	workers.Wait()
	close(results)

	out := make([]dokku.App, 0, len(names))
	for app := range results {
		out = append(out, app)
	}
	return out
}

func snapshotWorkerLimit(appCount int) int {
	if appCount <= 1 {
		return appCount
	}
	limit := 8
	if raw := strings.TrimSpace(os.Getenv("DASHBOARD_SNAPSHOT_WORKERS")); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil {
			limit = parsed
		}
	}
	if limit < 1 {
		limit = 1
	}
	if limit > 16 {
		limit = 16
	}
	if limit > appCount {
		limit = appCount
	}
	return limit
}

func (s *server) appsForTenant(ctx context.Context, tenant string) []dokku.App {
	if !s.tenantInScope(tenant) {
		return nil
	}
	snap, _ := s.snapshots.Snapshot()
	apps := make([]dokku.App, 0, 2)
	for _, app := range snap.Apps {
		if app.Tenant == tenant {
			apps = append(apps, app)
		}
	}
	if len(apps) == 0 {
		names, err := s.dokku.AppsList(ctx)
		if err == nil {
			for _, name := range names {
				if name == tenant+"-backend" || name == tenant+"-frontend" {
					apps = append(apps, s.dokku.AppSummary(ctx, name))
				}
			}
		}
	}
	sort.Slice(apps, func(i, j int) bool { return apps[i].Name < apps[j].Name })
	return apps
}

func (s *server) filterAppNames(names []string) []string {
	if s.cfg.TenantPrefix == "" {
		return names
	}
	out := make([]string, 0, len(names))
	for _, name := range names {
		if s.tenantInScope(tenantFromAppName(name)) {
			out = append(out, name)
		}
	}
	return out
}

func (s *server) tenantInScope(tenant string) bool {
	return s.cfg.TenantPrefix == "" || strings.HasPrefix(tenant, s.cfg.TenantPrefix)
}

func tenantFromAppName(name string) string {
	switch {
	case strings.HasSuffix(name, "-backend"):
		return strings.TrimSuffix(name, "-backend")
	case strings.HasSuffix(name, "-frontend"):
		return strings.TrimSuffix(name, "-frontend")
	default:
		return name
	}
}

func (s *server) render(w http.ResponseWriter, name string, data any) {
	t, ok := s.pages[name]
	if !ok {
		http.Error(w, "unknown template: "+name, http.StatusInternalServerError)
		return
	}
	if m, ok := data.(map[string]any); ok {
		pw := strings.TrimSpace(getenv("MYSQL_ROOT_PASSWORD"))
		user := strings.TrimSpace(getenv("MYSQL_ROOT_USER"))
		configured := pw != "" && pw != "changeme"
		m["MySQLConfigured"] = configured
		m["MySQLNeedsConfig"] = !configured
		m["MySQLAdminUser"] = user
		m["TenantPrefix"] = s.cfg.TenantPrefix
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := t.ExecuteTemplate(w, name, data); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

func (s *server) renderPartial(w http.ResponseWriter, name string, data any) {
	t, ok := s.pages[name]
	if !ok {
		http.Error(w, "unknown template: "+name, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := t.ExecuteTemplate(w, name, data); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

func getenv(key string) string {
	return os.Getenv(key)
}

var validName = func() func(string) bool {
	allowed := func(r rune) bool {
		return (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-'
	}
	return func(s string) bool {
		if s == "" || len(s) > 64 {
			return false
		}
		for _, r := range s {
			if !allowed(r) {
				return false
			}
		}
		return true
	}
}()

func validAppName(s string) bool { return validName(s) }

func stateClass(state string) string {
	switch state {
	case "running":
		return "bg-emerald-500/15 text-emerald-400 ring-emerald-500/30"
	case "restarting", "mixed", "created":
		return "bg-amber-500/15 text-amber-400 ring-amber-500/30"
	case "stopped", "exited", "dead", "paused":
		return "bg-rose-500/15 text-rose-400 ring-rose-500/30"
	case "not-deployed":
		return "bg-zinc-700/40 text-zinc-300 ring-zinc-500/30"
	default:
		return "bg-zinc-700/40 text-zinc-300 ring-zinc-500/30"
	}
}

func httpClass(code string) string {
	switch {
	case strings.HasPrefix(code, "2"), strings.HasPrefix(code, "3"):
		return "text-emerald-400"
	case code == "000", code == "":
		return "text-rose-400"
	default:
		return "text-amber-400"
	}
}
