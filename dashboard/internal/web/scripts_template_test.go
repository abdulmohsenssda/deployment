package web

import (
	"bytes"
	"html/template"
	"strings"
	"testing"
	"time"

	"github.com/abdul-mohsen/deployment/dashboard/internal/scripts"
)

func renderScriptsTemplate(t *testing.T) string {
	t.Helper()
	funcs := template.FuncMap{
		"join":     strings.Join,
		"now":      func() string { return time.Now().Format("2006-01-02 15:04:05") },
		"stateClr": stateClass,
		"httpClr":  httpClass,
		"json":     templateJSON,
	}
	tpl, err := template.New("").Funcs(funcs).ParseFS(tplFS,
		"templates/_layout.html",
		"templates/palette.html",
		"templates/scripts.html",
	)
	if err != nil {
		t.Fatalf("parse scripts template: %v", err)
	}

	var out bytes.Buffer
	data := map[string]any{
		"Env":           "test",
		"Scripts":       scripts.Catalog(),
		"CommandGroups": scripts.CommandGroups(),
	}
	if err := tpl.ExecuteTemplate(&out, "scripts.html", data); err != nil {
		t.Fatalf("execute scripts template: %v", err)
	}
	return out.String()
}

func commandGroupSection(t *testing.T, body, id string) string {
	t.Helper()
	marker := `data-command-group="` + id + `"`
	start := strings.Index(body, marker)
	if start < 0 {
		t.Fatalf("command group %q not rendered", id)
	}
	end := strings.Index(body[start+len(marker):], `data-command-group="`)
	if end < 0 {
		return body[start:]
	}
	return body[start : start+len(marker)+end]
}

func TestScriptsTemplateGroupsCommandsByOperatorIntent(t *testing.T) {
	body := renderScriptsTemplate(t)
	groups := []struct {
		id    string
		title string
		slug  []string
	}{
		{
			id:    "read-only-status",
			title: "Read-only / status",
			slug:  []string{"status", "list-tenants", "tail-logs", "verify-mysql", "discover-dokku-nginx", "watch-dokku-traffic"},
		},
		{
			id:    "deployment-lifecycle",
			title: "Deployment / lifecycle",
			slug:  []string{"create-tenant", "init-tenant-db", "deploy-all", "rollback-tenant", "set-tenant-image", "update-tenant", "fix-dokku-hostname", "setup-nats", "auto-pull", "setup-dev-tenant"},
		},
		{
			id:    "backup-restore",
			title: "Backup / restore",
			slug:  []string{"backup-tenant", "manage-backups", "restore-tenant"},
		},
		{
			id:    "cleanup-deletion",
			title: "Cleanup / deletion",
			slug:  []string{"remove-tenant", "cleanup-broken-tenant", "cleanup-old-files"},
		},
	}

	previous := -1
	seen := map[string]bool{}
	for _, group := range groups {
		titleAt := strings.Index(body, group.title)
		if titleAt < 0 {
			t.Fatalf("group title %q not rendered", group.title)
		}
		if titleAt <= previous {
			t.Fatalf("group %q is out of scan order", group.title)
		}
		previous = titleAt

		section := commandGroupSection(t, body, group.id)
		if !strings.Contains(section, group.title) {
			t.Fatalf("group %q section is missing its title", group.id)
		}
		for _, slug := range group.slug {
			marker := `data-script="` + slug + `"`
			if strings.Count(section, marker) != 1 {
				t.Errorf("expected %s in %s exactly once", slug, group.id)
			}
			if seen[slug] {
				t.Errorf("command %s appears in more than one group", slug)
			}
			seen[slug] = true
		}
	}

	catalog := scripts.Catalog()
	if len(seen) != len(catalog) {
		t.Fatalf("grouped %d commands, catalog contains %d", len(seen), len(catalog))
	}
	for _, script := range catalog {
		if !seen[script.Slug()] {
			t.Errorf("catalog command %s is not present in a group", script.Slug())
		}
		link := `href="/scripts/` + script.Slug() + `"`
		markerStart := strings.Index(body, `data-script="`+script.Slug()+`"`)
		if markerStart < 0 {
			t.Errorf("expected command card %s to preserve link %s", script.Slug(), link)
			continue
		}
		cardStart := strings.LastIndex(body[:markerStart], "<a ")
		if cardStart < 0 {
			t.Errorf("expected command card %s to preserve link %s", script.Slug(), link)
			continue
		}
		cardEnd := strings.Index(body[cardStart:], "</a>")
		if cardEnd < 0 || !strings.Contains(body[cardStart:cardStart+cardEnd], link) {
			t.Errorf("expected command card %s to preserve link %s", script.Slug(), link)
		}
	}
}

func TestScriptsTemplateLabelsCommandImpactAndDanger(t *testing.T) {
	body := renderScriptsTemplate(t)
	for _, script := range scripts.Catalog() {
		markerStart := strings.Index(body, `data-script="`+script.Slug()+`"`)
		if markerStart < 0 {
			t.Fatalf("command card %s not rendered", script.Slug())
		}
		start := strings.LastIndex(body[:markerStart], "<a ")
		if start < 0 {
			t.Fatalf("command card %s has no anchor", script.Slug())
		}
		end := strings.Index(body[start:], "</a>")
		if end < 0 {
			t.Fatalf("command card %s is not closed", script.Slug())
		}
		card := body[start : start+end]

		wantImpact := `data-impact="` + script.ImpactClass() + `"`
		if !strings.Contains(card, wantImpact) {
			t.Errorf("%s missing impact marker %s", script.Slug(), wantImpact)
		}
		wantDanger := `data-danger="` + map[bool]string{true: "true", false: "false"}[script.Danger] + `"`
		if !strings.Contains(card, wantDanger) {
			t.Errorf("%s missing danger marker %s", script.Slug(), wantDanger)
		}
		if !strings.Contains(card, script.ImpactLabel()) {
			t.Errorf("%s missing impact label %q", script.Slug(), script.ImpactLabel())
		}
		if script.Danger {
			if !strings.Contains(card, "cc-danger") || !strings.Contains(card, "Danger") || !strings.Contains(card, "Confirm before running") {
				t.Errorf("%s is dangerous but has no confirmation label", script.Slug())
			}
			if !strings.Contains(card, "command-card-danger") {
				t.Errorf("%s is dangerous but has no danger card treatment", script.Slug())
			}
		} else if strings.Contains(card, "cc-danger") || strings.Contains(card, "Confirm before running") {
			t.Errorf("%s is non-dangerous but has a danger label", script.Slug())
		}
	}
}
