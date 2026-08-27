package web

import (
	"encoding/json"
	"log"
	"net/http"
	"net/url"
	"strings"

	"github.com/abdul-mohsen/deployment/dashboard/internal/logbuf"
	"github.com/abdul-mohsen/deployment/dashboard/internal/scripts"
	"github.com/go-chi/chi/v5"
)

func activityKey(kind, name string) string {
	return "activity:" + kind + ":" + name
}

func (s *server) recordLog(key, line string) {
	if s.logs == nil {
		log.Printf("dashboard: log store is unavailable for %q", key)
		return
	}
	if err := s.logs.Append(key, line); err != nil {
		log.Printf("dashboard: persist log %q: %v", key, err)
	}
}

func (s *server) recordActivity(key, line string) {
	s.recordLog(key, line)
}

func (s *server) recordActivities(keys []string, line string) {
	for _, key := range keys {
		s.recordActivity(key, line)
	}
}

func (s *server) recordActivityBlock(key, output string) {
	output = strings.TrimRight(output, "\r\n")
	if output == "" {
		return
	}
	for _, line := range strings.Split(output, "\n") {
		s.recordActivity(key, strings.TrimSuffix(line, "\r"))
	}
}

func scriptActivityKeys(sc *scripts.Script, form url.Values) []string {
	keys := []string{activityKey("script", sc.Slug())}
	tenant := strings.TrimSpace(form.Get("_pos_name"))
	if tenant == "" {
		tenant = strings.TrimSpace(form.Get("tenant"))
	}
	if validAppName(tenant) {
		keys = append(keys, activityKey("tenant", tenant))
	}
	return keys
}

func (s *server) writeActivity(w http.ResponseWriter, key string) {
	entries := make([]logbuf.Entry, 0)
	if s.logs != nil {
		entries = s.logs.Snapshot(key)
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"entries": entries})
}

func (s *server) handleTenantActivity(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	if !validAppName(name) {
		http.Error(w, "invalid name", http.StatusBadRequest)
		return
	}
	s.writeActivity(w, activityKey("tenant", name))
}

func (s *server) handleAppActivity(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	if !validAppName(name) {
		http.Error(w, "invalid name", http.StatusBadRequest)
		return
	}
	s.writeActivity(w, activityKey("app", name))
}

func (s *server) handleScriptActivity(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	sc := scripts.Find(name)
	if sc == nil {
		http.NotFound(w, r)
		return
	}
	s.writeActivity(w, activityKey("script", sc.Slug()))
}
