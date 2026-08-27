package web

import (
	"html/template"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/abdul-mohsen/deployment/dashboard/internal/dokku"
	"github.com/abdul-mohsen/deployment/dashboard/internal/scripts"
)

func embeddedTemplate(t *testing.T, name string) string {
	t.Helper()
	data, err := tplFS.ReadFile("templates/" + name)
	if err != nil {
		t.Fatalf("read %s: %v", name, err)
	}
	return string(data)
}

func TestPageTitleForRouteContext(t *testing.T) {
	script := &scripts.Script{Title: "Create tenant"}
	tests := []struct {
		name string
		data map[string]any
		want string
	}{
		{name: "login.html", want: "Sign in"},
		{name: "index.html", want: "Tenant Fleet"},
		{name: "app.html", data: map[string]any{"App": dokku.App{Name: "dev-acme-backend"}}, want: "dev-acme-backend"},
		{name: "tenant.html", data: map[string]any{"Tenant": "dev-acme"}, want: "dev-acme"},
		{name: "scripts.html", want: "Deployment Commands"},
		{name: "script.html", data: map[string]any{"Script": script}, want: "Create tenant"},
		{name: "releases.html", want: "Version Catalog"},
		{name: "password.html", want: "Password"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := pageTitleFor(tt.name, tt.data); got != tt.want {
				t.Fatalf("pageTitleFor(%q) = %q, want %q", tt.name, got, tt.want)
			}
		})
	}
}

func TestRenderAddsContextualPageTitle(t *testing.T) {
	page := template.Must(template.New("app.html").Parse(`{{define "app.html"}}<title>{{.PageTitle}}</title>{{end}}`))
	srv := &server{pages: map[string]*template.Template{"app.html": page}}
	w := httptest.NewRecorder()

	srv.render(w, "app.html", map[string]any{
		"App": dokku.App{Name: "dev-acme-backend"},
	})

	if got := strings.TrimSpace(w.Body.String()); got != "<title>dev-acme-backend</title>" {
		t.Fatalf("rendered title = %q", got)
	}
}

func TestDashboardLayoutUsesContextualTitleAndAccessibleNavigation(t *testing.T) {
	layout := embeddedTemplate(t, "_layout.html")
	for _, want := range []string{
		"<title>{{if .PageTitle}}{{.PageTitle}} · {{end}}Dokku Control Plane{{if .Env}} · {{.Env}}{{end}}</title>",
		`<nav class="topnav-links" aria-label="Primary navigation">`,
		`aria-label="Dokku Control Plane home"`,
		`aria-label="Access settings"`,
		`aria-label="Search (⌘K)"`,
		`aria-label="Sign out"`,
	} {
		if !strings.Contains(layout, want) {
			t.Errorf("_layout.html is missing %q", want)
		}
	}
}

func TestLoginTemplateHasSemanticLandmarksAndLabels(t *testing.T) {
	login := embeddedTemplate(t, "login.html")
	for _, want := range []string{
		`<main aria-labelledby="login-heading"`,
		`<h1 id="login-heading"`,
		`<label for="login-user">`,
		`<input id="login-user"`,
		`<label for="login-password">`,
		`<input id="login-password"`,
	} {
		if !strings.Contains(login, want) {
			t.Errorf("login.html is missing %q", want)
		}
	}
}

func TestPaletteTemplateHasAccessibleDialogAndSearch(t *testing.T) {
	palette := embeddedTemplate(t, "palette.html")
	for _, want := range []string{
		`role="dialog"`,
		`aria-modal="true"`,
		`aria-label="Command palette"`,
		`aria-label="Search apps and commands"`,
	} {
		if !strings.Contains(palette, want) {
			t.Errorf("palette.html is missing %q", want)
		}
	}
}

func TestAsyncOutputRegionsHaveAccessibleSemantics(t *testing.T) {
	tests := map[string][]string{
		"_layout.html": {
			`id="toast" class="toast-container" role="status" aria-live="polite" aria-atomic="true" aria-relevant="text"`,
			`id="toast-status" class="sr-only"`,
		},
		"index.html": {
			`id="tenant-stream-status" class="sr-only" role="status" aria-live="polite" aria-atomic="true"`,
			`aria-busy="true" aria-describedby="tenant-stream-status"`,
			`<caption class="sr-only">Tenant fleet status</caption>`,
			`<th class="col-name" scope="col">Tenant</th>`,
		},
		"app.html": {
			`id="logs" class="terminal" role="log" aria-live="polite" aria-atomic="false"`,
			`aria-relevant="additions" aria-busy="true" aria-labelledby="app-logs-title"`,
			`id="log-stream-status" class="badge badge-info" role="status" aria-live="polite"`,
			`aria-controls="logs" aria-busy="false"`,
		},
		"script.html": {
			`id="out" class="terminal" role="log" aria-live="polite" aria-atomic="false"`,
			`aria-relevant="additions" aria-busy="false" aria-labelledby="command-output-title"`,
			`id="run-status" class="alert" role="status" aria-live="polite"`,
		},
		"tenant.html": {
			`id="tenant-out" class="terminal" role="log" aria-live="polite" aria-atomic="false"`,
			`aria-relevant="additions" aria-busy="false"`,
			`id="backup-table" aria-busy="true"`,
			`id="backup-status" class="sr-only" role="status" aria-live="polite" aria-atomic="true"`,
			`role="dialog" aria-modal="true" aria-labelledby="restore-modal-title"`,
			`aria-describedby="restore-modal-desc" aria-hidden="true"`,
		},
	}

	for path, want := range tests {
		text := embeddedTemplate(t, path)
		for _, token := range want {
			if !strings.Contains(text, token) {
				t.Errorf("%s is missing accessibility token %q", path, token)
			}
		}
	}
}

func TestToastUsesOneAnnouncedRegionAndHiddenVisualCopies(t *testing.T) {
	layout := embeddedTemplate(t, "_layout.html")
	if strings.Count(layout, `id="toast"`) != 1 || strings.Count(layout, `role="status"`) != 1 {
		t.Fatal("layout should expose one toast status region")
	}

	appJS, err := staticFS.ReadFile("static/app.js")
	if err != nil {
		t.Fatalf("read app.js: %v", err)
	}
	source := string(appJS)
	for _, token := range []string{
		`const toastStatus = document.getElementById('toast-status')`,
		`el.setAttribute('aria-hidden', 'true')`,
		`toastStatus.textContent = msg`,
	} {
		if !strings.Contains(source, token) {
			t.Errorf("app.js is missing toast accessibility token %q", token)
		}
	}
}

func TestTerminalOutputAppendsIncrementalLines(t *testing.T) {
	for _, path := range []string{"script.html", "tenant.html"} {
		text := embeddedTemplate(t, path)
		if !strings.Contains(text, `className = 'terminal-line'`) {
			t.Errorf("%s should append output as individual terminal lines", path)
		}
	}
	if !strings.Contains(embeddedTemplate(t, "app.html"), `data-stream-url="/apps/{{.Name}}/logs"`) {
		t.Fatal("app.html should expose the shared bounded log stream")
	}
}

func TestAsyncOutputSkipsDecorativeAnnouncements(t *testing.T) {
	script := embeddedTemplate(t, "script.html")
	if !strings.Contains(script, `appendLine('--- run ' + new Date().toISOString() + ' ---', true, false)`) {
		t.Fatal("command output run separators should not be announced")
	}

	tenant := embeddedTemplate(t, "tenant.html")
	if !strings.Contains(tenant, `append('--- ' + method + ' ' + url + ' @ ' + new Date().toISOString() + ' ---', true, false)`) {
		t.Fatal("tenant action separators should not be announced")
	}
}
