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
