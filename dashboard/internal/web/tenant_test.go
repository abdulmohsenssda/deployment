package web

import (
	"bytes"
	"html/template"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/abdul-mohsen/deployment/dashboard/internal/dokku"
)

func renderTenantContent(t *testing.T, data map[string]any) string {
	t.Helper()
	tmpl := template.Must(template.New("tenant.html").Funcs(templateFuncs()).ParseFS(tplFS, "templates/tenant.html"))

	var rendered bytes.Buffer
	if err := tmpl.ExecuteTemplate(&rendered, "content", data); err != nil {
		t.Fatalf("render tenant template: %v", err)
	}
	return rendered.String()
}

func tenantTemplateData(backend, frontend *dokku.App) map[string]any {
	return map[string]any{
		"Tenant":         "acme",
		"Backend":        backend,
		"Frontend":       frontend,
		"AutoRedeploy":   false,
		"MaxUserBackups": 50,
		"DefaultVersion": "v1.2.3",
	}
}

func TestTenantTemplateLinksToAvailableAppDetails(t *testing.T) {
	backend := &dokku.App{Name: "acme-backend", State: "running", HTTPCode: "200"}
	frontend := &dokku.App{Name: "acme-frontend", State: "running", Domains: []string{"acme.example.test"}}

	rendered := renderTenantContent(t, tenantTemplateData(backend, frontend))

	for _, want := range []string{
		`href="/apps/acme-backend"`,
		`View backend app details`,
		`href="/apps/acme-frontend"`,
		`View frontend app details`,
		`href="/scripts/update-tenant?_pos_name=acme"`,
		`href="/scripts/tail-logs?tenant=acme"`,
		`href="/tenants/acme/accounting-export"`,
		`href="/scripts/remove-tenant?_pos_name=acme"`,
	} {
		if !strings.Contains(rendered, want) {
			t.Errorf("rendered tenant page missing %q", want)
		}
	}
	if strings.Contains(rendered, "app unavailable") {
		t.Fatalf("available app cards incorrectly rendered unavailable state: %s", rendered)
	}
}

func TestTenantTemplateShowsUnavailableAppCards(t *testing.T) {
	rendered := renderTenantContent(t, tenantTemplateData(nil, nil))

	for _, want := range []string{
		"Backend app unavailable",
		"Frontend app unavailable",
		`class="badge state-missing">Unavailable`,
	} {
		if !strings.Contains(rendered, want) {
			t.Errorf("rendered tenant page missing unavailable marker %q", want)
		}
	}
	if strings.Contains(rendered, `href="/apps/`) {
		t.Fatalf("unavailable app cards must not expose app-detail links: %s", rendered)
	}
}

func TestAppDetailURLRejectsUnsafeNames(t *testing.T) {
	tests := []struct {
		name string
		want string
	}{
		{name: "acme-backend", want: "/apps/acme-backend"},
		{name: "acme/backend", want: ""},
		{name: "acme?next=evil", want: ""},
		{name: "", want: ""},
	}
	for _, tc := range tests {
		if got := appDetailURL(tc.name); got != tc.want {
			t.Errorf("appDetailURL(%q) = %q, want %q", tc.name, got, tc.want)
		}
	}
}

func TestTenantDetailRequiresAuth(t *testing.T) {
	handler := testRouter(t)
	req := httptest.NewRequest(http.MethodGet, "/tenants/acme", nil)
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)

	if rr.Code != http.StatusSeeOther {
		t.Fatalf("GET /tenants/acme without auth returned %d, want %d", rr.Code, http.StatusSeeOther)
	}
	if location := rr.Header().Get("Location"); location != "/login" {
		t.Errorf("unauthorized tenant detail redirect = %q, want /login", location)
	}
}
