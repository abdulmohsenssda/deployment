// Package web — backup and restore handlers.
package web

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
)

// ── Backup manifest struct —————————————————————————————————————————————————
// Mirrors the JSON written by backup-tenant.sh / manage-backups.sh.

type backupManifest struct {
	ID            string `json:"id"`
	Tenant        string `json:"tenant"`
	Timestamp     string `json:"timestamp"`
	Origin        string `json:"origin"`
	Owner         string `json:"owner"`
	FilesArtifact string `json:"files_artifact"`
	DBArtifact    string `json:"db_artifact"`
	Label         string `json:"label,omitempty"`
	Verified      bool   `json:"verified"`
	CreatedAt     string `json:"created_at"`
}

// ── validBackupID validates backup IDs of the form "<tenant>_<YYYYMMDD_HHMMSS>". ──
// Only alphanumerics, hyphens, and underscores are allowed.
func validBackupID(id string) bool {
	if id == "" || len(id) > 80 {
		return false
	}
	for _, r := range id {
		if !((r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') ||
			(r >= '0' && r <= '9') || r == '-' || r == '_') {
			return false
		}
	}
	return true
}

func backupDirPath(dir string) string {
	if strings.TrimSpace(dir) == "" {
		return "/opt/tenant-backups"
	}
	return dir
}

// backupArtifactPath only permits artifacts stored directly in the configured
// backup directory. Manifest contents are server-controlled files, but still
// must not be able to turn a download into an arbitrary file read.
func backupArtifactPath(dir, artifact string) (string, error) {
	if artifact == "" || filepath.IsAbs(artifact) ||
		filepath.Base(artifact) != artifact ||
		strings.ContainsAny(artifact, `/\`) {
		return "", fmt.Errorf("invalid backup artifact")
	}
	root, err := filepath.Abs(backupDirPath(dir))
	if err != nil {
		return "", err
	}
	path, err := filepath.Abs(filepath.Join(root, artifact))
	if err != nil {
		return "", err
	}
	rel, err := filepath.Rel(root, path)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("backup artifact escapes backup directory")
	}
	return path, nil
}

// ── listBackupsForTenant reads .meta.json files directly from the backup dir ──
// This avoids running a sidecar container just to list files — the backup dir
// is mounted directly into the dashboard container via BACKUP_DIR env / volume.

func (s *server) listBackupsForTenant(ctx context.Context, tenant string) ([]backupManifest, error) {
	backupDir := backupDirPath(s.cfg.BackupDir)

	// Glob for all manifest files belonging to this tenant
	pattern := filepath.Join(backupDir, tenant+"_*.meta.json")
	matches, err := filepath.Glob(pattern)
	if err != nil {
		return nil, fmt.Errorf("glob backup manifests: %w", err)
	}

	manifests := make([]backupManifest, 0, len(matches))
	for _, path := range matches {
		data, err := os.ReadFile(path)
		if err != nil {
			continue // skip unreadable files
		}
		var m backupManifest
		if err := json.Unmarshal(data, &m); err != nil {
			continue // skip malformed manifests
		}
		// Double-check tenant matches (manifest may contain the tenant field)
		if m.Tenant != "" && m.Tenant != tenant {
			continue
		}
		// Populate ID from filename if missing: <tenant>_<timestamp>.meta.json
		if m.ID == "" {
			base := filepath.Base(path)
			m.ID = strings.TrimSuffix(base, ".meta.json")
		}
		// Populate CreatedAt from Timestamp if missing
		if m.CreatedAt == "" && m.Timestamp != "" {
			m.CreatedAt = m.Timestamp
		}
		manifests = append(manifests, m)
	}

	// Sort newest first
	sort.Slice(manifests, func(i, j int) bool {
		ti := manifests[i].CreatedAt
		if ti == "" {
			ti = manifests[i].Timestamp
		}
		tj := manifests[j].CreatedAt
		if tj == "" {
			tj = manifests[j].Timestamp
		}
		return ti > tj
	})

	return manifests, nil
}

// runScriptCapture runs a script and captures stdout+stderr, returning combined output.
// The backup dir is mounted so scripts can write/read backup files on the host.
func (s *server) runScriptCapture(ctx context.Context, scriptName string, argv []string) ([]byte, error) {
	if s.cfg.ScriptsHostPath == "" {
		return nil, fmt.Errorf("SCRIPTS_HOST_PATH not configured")
	}

	// Docker socket detection (same logic as Runner.Run)
	dockerSocket := "/var/run/docker.sock:/var/run/docker.sock"
	if _, err := os.Stat(`\\.\pipe\dockerDesktopLinuxEngine`); err == nil {
		dockerSocket = `//./pipe/dockerDesktopLinuxEngine://./pipe/dockerDesktopLinuxEngine`
	} else if _, err := os.Stat(`\\.\pipe\docker_engine`); err == nil {
		dockerSocket = `//./pipe/docker_engine://./pipe/docker_engine`
	}

	configFlag := ""
	if s.cfg.ConfigFile != "" {
		configFlag = " --config /tmp/dep-cap/config.env"
	}

	bashScript := fmt.Sprintf(`set -e
mkdir -p /tmp/dep-cap
cp -r /opt/deployment/scripts /tmp/dep-cap/
[ -f /opt/deployment/config.env ] && cp /opt/deployment/config.env /tmp/dep-cap/ || true
find /tmp/dep-cap -name '*.sh' -exec sed -i 's/\r$//' {} +
cd /tmp/dep-cap
NAME="$1"; shift
exec bash "scripts/deployctl.sh" "script" "$NAME" "$@"%s`, configFlag)

	backupDir := s.cfg.BackupDir
	if backupDir == "" {
		backupDir = "/opt/tenant-backups"
	}

	full := []string{
		"run", "--rm", "-i",
		"-e", "MYSQL_CLIENT_MODE=docker",
		"-e", "TENANT_NAME_PREFIX=" + os.Getenv("TENANT_NAME_PREFIX"),
		"-e", "BACKUP_DIR=" + backupDir,
		"-v", dockerSocket,
		"-v", s.cfg.ScriptsHostPath + ":/opt/deployment:ro",
		"-v", backupDir + ":" + backupDir,
		"--network", "host",
		s.cfg.RunnerImage,
		"bash", "-c", bashScript,
		"--", scriptName,
	}
	full = append(full, argv...)

	cmd := exec.CommandContext(ctx, s.cfg.DockerBin, full...)
	cmd.Env = append(os.Environ(), "TERM=dumb")
	return cmd.CombinedOutput()
}

// ── POST /tenants/{name}/backup ───────────────────────────────────────────────

func (s *server) handleTenantBackup(w http.ResponseWriter, r *http.Request) {
	tenant := chi.URLParam(r, "name")
	if !validAppName(tenant) {
		http.Error(w, "invalid name", http.StatusBadRequest)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad form", http.StatusBadRequest)
		return
	}
	label := strings.TrimSpace(r.FormValue("label"))
	if len(label) > 120 || strings.IndexFunc(label, func(r rune) bool {
		return r < 0x20 || r == 0x7f
	}) >= 0 {
		http.Error(w, "backup label must be at most 120 printable characters", http.StatusBadRequest)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Minute)
	defer cancel()

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	fmt.Fprintf(w, "data: Starting backup for %s...\n\n", tenant)
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}

	argv := []string{tenant, "--origin", "user", "--owner", "dashboard"}
	if label != "" {
		argv = append(argv, "--label", label)
	}
	activity := activityKey("tenant", tenant)
	s.recordActivity(activity, fmt.Sprintf("--- create backup for %s @ %s ---", tenant, time.Now().UTC().Format(time.RFC3339)))
	s.recordActivity(activity, "Starting backup for "+tenant+"...")
	runErr := s.runner.RunWithCallback(ctx, w, "backup-tenant.sh", argv, func(line string) {
		s.recordActivity(activity, line)
	})
	if runErr != nil {
		s.recordActivity(activity, "ERROR: "+runErr.Error())
		fmt.Fprintf(w, "event: error\ndata: %s\n\n", runErr.Error())
		s.recordActivity(activity, "--- backup failed ---")
	} else {
		s.recordActivity(activity, "--- backup complete ---")
	}
	fmt.Fprint(w, "event: done\ndata: end\n\n")
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}
}

// ── GET /tenants/{name}/backups ───────────────────────────────────────────────

func (s *server) handleTenantBackupList(w http.ResponseWriter, r *http.Request) {
	tenant := chi.URLParam(r, "name")
	if !validAppName(tenant) {
		http.Error(w, "invalid name", http.StatusBadRequest)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()

	manifests, err := s.listBackupsForTenant(ctx, tenant)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"backups": manifests})
}

// ── GET /tenants/{name}/backups/{id}/download ────────────────────────────────

func (s *server) handleTenantBackupDownload(w http.ResponseWriter, r *http.Request) {
	tenant := chi.URLParam(r, "name")
	backupID := chi.URLParam(r, "id")
	if !validAppName(tenant) || !validBackupID(backupID) {
		http.Error(w, "invalid params", http.StatusBadRequest)
		return
	}

	backupDir := backupDirPath(s.cfg.BackupDir)
	metaPath := filepath.Join(backupDir, backupID+".meta.json")
	data, err := os.ReadFile(metaPath)
	if err != nil {
		http.Error(w, "backup not found", http.StatusNotFound)
		return
	}
	var m backupManifest
	if err := json.Unmarshal(data, &m); err != nil || m.DBArtifact == "" {
		http.Error(w, "no SQL artifact in backup manifest", http.StatusNotFound)
		return
	}
	// Security: ensure the tenant matches
	if m.Tenant != "" && m.Tenant != tenant {
		http.Error(w, "backup belongs to a different tenant", http.StatusForbidden)
		return
	}

	sqlPath, err := backupArtifactPath(backupDir, m.DBArtifact)
	if err != nil {
		http.Error(w, "invalid SQL artifact path", http.StatusInternalServerError)
		return
	}
	f, err := os.Open(sqlPath)
	if err != nil {
		http.Error(w, "SQL artifact file not found", http.StatusNotFound)
		return
	}
	defer f.Close()

	contentType := "application/octet-stream"
	if strings.HasSuffix(m.DBArtifact, ".gz") {
		contentType = "application/gzip"
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s"`, filepath.Base(m.DBArtifact)))

	_, _ = io.Copy(w, f)
}

// ── POST /tenants/{name}/backups/{id}/delete ─────────────────────────────────

func (s *server) handleTenantBackupDelete(w http.ResponseWriter, r *http.Request) {
	tenant := chi.URLParam(r, "name")
	backupID := chi.URLParam(r, "id")
	if !validAppName(tenant) || !validBackupID(backupID) {
		http.Error(w, "invalid params", http.StatusBadRequest)
		return
	}

	// Verify the backup belongs to this tenant and is user-origin
	backupDir := backupDirPath(s.cfg.BackupDir)
	metaPath := filepath.Join(backupDir, backupID+".meta.json")
	data, err := os.ReadFile(metaPath)
	if err != nil {
		http.Error(w, "backup not found", http.StatusNotFound)
		return
	}
	var m backupManifest
	if err := json.Unmarshal(data, &m); err != nil {
		http.Error(w, "invalid backup manifest", http.StatusInternalServerError)
		return
	}
	if m.Tenant != "" && m.Tenant != tenant {
		http.Error(w, "backup belongs to a different tenant", http.StatusForbidden)
		return
	}
	if m.Origin != "user" {
		http.Error(w, "only user-origin backups can be deleted via the UI", http.StatusForbidden)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()

	// manage-backups.sh delete <id> --force (dashboard has operator authority)
	argv := []string{"delete", backupID, "--force"}
	activity := activityKey("tenant", tenant)
	s.recordActivity(activity, fmt.Sprintf("--- delete backup %s @ %s ---", backupID, time.Now().UTC().Format(time.RFC3339)))
	out, err := s.runScriptCapture(ctx, "manage-backups.sh", argv)
	s.recordActivityBlock(activity, string(out))
	if err != nil {
		s.recordActivity(activity, "ERROR: "+err.Error())
		http.Error(w, "delete failed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	s.recordActivity(activity, "--- backup delete complete ---")
	w.WriteHeader(http.StatusNoContent)
}

// ── POST /tenants/{name}/backups/{id}/restore ────────────────────────────────

func (s *server) handleTenantRestore(w http.ResponseWriter, r *http.Request) {
	tenant := chi.URLParam(r, "name")
	backupID := chi.URLParam(r, "id")
	if !validAppName(tenant) || !validBackupID(backupID) {
		http.Error(w, "invalid params", http.StatusBadRequest)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Minute)
	defer cancel()

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	fmt.Fprintf(w, "data: Restoring %s from backup %s...\n\n", tenant, backupID)
	fmt.Fprint(w, "data: A safety backup of the current state will be taken first.\n\n")
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}

	// restore-tenant.sh <tenant> --from <id> (takes safety backup by default)
	argv := []string{tenant, "--from", backupID}
	activity := activityKey("tenant", tenant)
	s.recordActivity(activity, fmt.Sprintf("--- restore %s from %s @ %s ---", tenant, backupID, time.Now().UTC().Format(time.RFC3339)))
	s.recordActivity(activity, "Restoring "+tenant+" from backup "+backupID+"...")
	s.recordActivity(activity, "A safety backup of the current state will be taken first.")
	runErr := s.runner.RunWithCallback(ctx, w, "restore-tenant.sh", argv, func(line string) {
		s.recordActivity(activity, line)
	})
	if runErr != nil {
		s.recordActivity(activity, "ERROR: "+runErr.Error())
		fmt.Fprintf(w, "event: error\ndata: %s\n\n", runErr.Error())
		s.recordActivity(activity, "--- restore failed ---")
	} else {
		s.recordActivity(activity, "--- restore complete ---")
	}
	fmt.Fprint(w, "event: done\ndata: end\n\n")
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}
}

// ── GET /tenants/{name}/accounting-export ────────────────────────────────────

func (s *server) handleAccountingExport(w http.ResponseWriter, r *http.Request) {
	tenant := chi.URLParam(r, "name")
	if !validAppName(tenant) {
		http.Error(w, "invalid name", http.StatusBadRequest)
		return
	}

	// Derive database name: "tenant_" + name with hyphens → underscores.
	// Actual DB naming: tenant_dev_git, tenant_qa_realtest1, etc.
	dbName := "tenant_" + strings.ReplaceAll(tenant, "-", "_")
	host := s.cfg.MySQLHost
	port := s.cfg.MySQLPort
	user := strings.TrimSpace(os.Getenv("MYSQL_ROOT_USER"))
	if user == "" {
		user = "root"
	}
	password := os.Getenv("MYSQL_ROOT_PASSWORD")

	dsn := fmt.Sprintf("%s:%s@tcp(%s:%s)/%s?parseTime=true&timeout=30s",
		user, password, host, port, dbName)

	f, err := buildAccountingExcel(r.Context(), dsn, tenant)
	if err != nil {
		http.Error(w, "export failed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	defer f.Close()

	filename := fmt.Sprintf("accounting_%s_%s.xlsx", tenant, time.Now().Format("20060102_150405"))
	w.Header().Set("Content-Type", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s"`, filename))
	if err := f.Write(w); err != nil {
		// Headers already sent; nothing we can do
		return
	}
}
