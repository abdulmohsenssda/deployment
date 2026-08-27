package web

import (
	"bytes"
	"context"
	"html/template"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/abdul-mohsen/deployment/dashboard/internal/scripts"
	"github.com/go-chi/chi/v5"
)

func TestImageTagMetadataMarksLatestV001DevAndMissing(t *testing.T) {
	bTags := map[string]bool{"v0.0.1": true, "dev": true, "pr-123": true}
	fTags := map[string]bool{"latest": true, "dev": true, "pr-123": true}
	_, metas := imageTagMetadata(bTags, fTags, "", nil)

	got := map[string]TagMeta{}
	for _, meta := range metas {
		got[meta.Tag] = meta
	}
	for _, tag := range []string{"latest", "v0.0.1", "dev"} {
		if _, ok := got[tag]; !ok {
			t.Fatalf("metadata missing %q: %+v", tag, metas)
		}
	}
	if got["latest"].InBoth || !got["latest"].FrontendOnly {
		t.Fatalf("latest coverage = %+v, want frontend-only", got["latest"])
	}
	if got["v0.0.1"].InBoth || !got["v0.0.1"].BackendOnly {
		t.Fatalf("v0.0.1 coverage = %+v, want backend-only", got["v0.0.1"])
	}
	if !got["dev"].InBoth || got["dev"].BackendOnly || got["dev"].FrontendOnly {
		t.Fatalf("dev coverage = %+v, want both repositories", got["dev"])
	}
	if _, ok := got["missing"]; ok {
		t.Fatal("missing tag must not appear in repository metadata")
	}
	if gotTag := recommendedImageTag(metas, "v0.0.1", "both"); gotTag != "dev" {
		t.Fatalf("recommendedImageTag = %q, want dev", gotTag)
	}
	if gotTag := recommendedImageTag([]TagMeta{{Tag: "latest", FrontendOnly: true}}, "dev", "both"); gotTag != "" {
		t.Fatalf("recommendedImageTag without a compatible tag = %q, want empty", gotTag)
	}
}

func TestNormalizeImageSelectionUsesCompatibleDefaultAndRejectsMissingTags(t *testing.T) {
	t.Setenv("BACKEND_IMAGE", "example/api")
	t.Setenv("FRONTEND_IMAGE", "example/web")
	t.Setenv("APP_IMAGE_VERSION_DEFAULT", "v0.0.1")
	t.Setenv("APP_IMAGE_VERSIONS", "v0.0.1")

	bTags := map[string]bool{"v0.0.1": true, "dev": true, "pr-123": true}
	fTags := map[string]bool{"latest": true, "dev": true, "pr-123": true}
	s := &server{
		imageTags: func(_ context.Context, _, _ string) (map[string]bool, map[string]bool, error) {
			return bTags, fTags, nil
		},
	}
	sc := scripts.Find("create-tenant.sh")
	if sc == nil {
		t.Fatal("create-tenant.sh not in catalog")
	}

	form, err := s.normalizeImageSelection(t.Context(), sc, nil)
	if err != nil {
		t.Fatalf("normalize default: %v", err)
	}
	if got := form.Get("image_version"); got != "dev" {
		t.Fatalf("default image tag = %q, want dev", got)
	}

	for _, tc := range []struct {
		name string
		tag  string
		want string
	}{
		{name: "latest", tag: "latest", want: "backend"},
		{name: "v0.0.1", tag: "v0.0.1", want: "frontend"},
		{name: "missing", tag: "missing", want: "backend and frontend"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := s.normalizeImageSelection(t.Context(), sc, mapValues("image_version", tc.tag))
			if err == nil {
				t.Fatalf("expected incompatible %s tag to fail", tc.tag)
			}
			if !strings.Contains(err.Error(), tc.tag) || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("error = %q, want tag and %q", err, tc.want)
			}
		})
	}
	if _, err := s.normalizeImageSelection(t.Context(), sc, mapValues("image_version", "pr-123")); err != nil {
		t.Fatalf("branch/PR tag rejected: %v", err)
	}
	_, err = s.normalizeImageSelection(t.Context(), sc, url.Values{
		"backend_image": {"example/api:latest"},
	})
	if err == nil || !strings.Contains(err.Error(), "latest") {
		t.Fatalf("incompatible hidden backend image was accepted: %v", err)
	}
}

func TestNormalizeImageSelectionAllowsRoleSpecificTags(t *testing.T) {
	t.Setenv("BACKEND_IMAGE", "example/api")
	t.Setenv("FRONTEND_IMAGE", "example/web")
	s := &server{
		imageTags: func(_ context.Context, _, _ string) (map[string]bool, map[string]bool, error) {
			return map[string]bool{"v0.0.1": true}, map[string]bool{"latest": true}, nil
		},
	}
	sc := scripts.Find("deploy-all.sh")
	if sc == nil {
		t.Fatal("deploy-all.sh not in catalog")
	}
	for _, form := range []url.Values{
		{"image_version": {"v0.0.1"}, "type": {"backend"}},
		{"image_version": {"latest"}, "type": {"frontend"}},
	} {
		if _, err := s.normalizeImageSelection(t.Context(), sc, form); err != nil {
			t.Fatalf("role-specific tag rejected: %v", err)
		}
	}
}

func TestHandleScriptRunRejectsIncompatibleTagBeforeRunner(t *testing.T) {
	t.Setenv("BACKEND_IMAGE", "example/api")
	t.Setenv("FRONTEND_IMAGE", "example/web")
	s := &server{
		imageTags: func(_ context.Context, _, _ string) (map[string]bool, map[string]bool, error) {
			return map[string]bool{"v0.0.1": true, "dev": true}, map[string]bool{"latest": true, "dev": true}, nil
		},
	}
	r := chi.NewRouter()
	r.Post("/scripts/{name}/run", s.handleScriptRun)
	req := httptest.NewRequest(http.MethodPost, "/scripts/create-tenant/run",
		strings.NewReader(url.Values{"image_version": {"latest"}}.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rr := httptest.NewRecorder()
	r.ServeHTTP(rr, req)

	if rr.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, "latest") || !strings.Contains(body, "backend") {
		t.Fatalf("response = %q, want clear compatibility feedback", body)
	}
}

func TestImageVersionFieldsDeclareCompatibilityScope(t *testing.T) {
	cases := map[string]string{
		"create-tenant.sh":    "both",
		"update-tenant.sh":    "both",
		"init-tenant-db.sh":   "backend",
		"deploy-all.sh":       "role",
		"rollback-tenant.sh":  "role",
		"set-tenant-image.sh": "role",
	}
	for name, want := range cases {
		sc := scripts.Find(name)
		if sc == nil {
			t.Fatalf("%s not in catalog", name)
		}
		var got string
		for _, field := range sc.Fields {
			if field.Name == "image_version" {
				got = field.ImageScope
				break
			}
		}
		if got != want {
			t.Errorf("%s image scope = %q, want %q", name, got, want)
		}
	}
}

func TestScriptTemplateRendersImageCompatibilityScope(t *testing.T) {
	funcs := template.FuncMap{
		"join":     strings.Join,
		"now":      func() string { return "2026-01-01 00:00:00" },
		"stateClr": stateClass,
		"httpClr":  httpClass,
		"json":     templateJSON,
	}
	page := template.Must(template.New("").Funcs(funcs).ParseFS(
		tplFS,
		"templates/_layout.html",
		"templates/palette.html",
		"templates/script.html",
	))
	var out bytes.Buffer
	data := map[string]any{
		"Env":              "test",
		"Script":           scripts.Find("create-tenant.sh"),
		"Releases":         []scripts.ImageVersion{},
		"DefaultVersion":   "dev",
		"RunnerConfigured": true,
	}
	if err := page.ExecuteTemplate(&out, "script.html", data); err != nil {
		t.Fatalf("render script template: %v", err)
	}
	if !strings.Contains(out.String(), `data-image-scope="both"`) {
		t.Fatal("create-tenant template omitted full-flow image scope")
	}
	if !strings.Contains(out.String(), "data-image-compatibility") {
		t.Fatal("create-tenant template omitted compatibility feedback element")
	}

	out.Reset()
	data["Script"] = scripts.Find("setup-dev-tenant.sh")
	if err := page.ExecuteTemplate(&out, "script.html", data); err != nil {
		t.Fatalf("render setup-dev template: %v", err)
	}
	if !strings.Contains(out.String(), `name="tag"`) ||
		!strings.Contains(out.String(), `data-image-scope="role"`) {
		t.Fatal("setup-dev template omitted role-specific image metadata")
	}
}

func TestSetupDevTenantUsesBackendDefaultAndRoleMetadata(t *testing.T) {
	sc := scripts.Find("setup-dev-tenant.sh")
	if sc == nil {
		t.Fatal("setup-dev-tenant.sh not in catalog")
	}
	for _, field := range sc.Fields {
		if field.Name == "tag" {
			if field.ImageScope != "role" {
				t.Fatalf("setup-dev-tenant tag scope = %q, want role", field.ImageScope)
			}
			return
		}
	}
	t.Fatal("setup-dev-tenant tag field missing")
}

func TestNormalizeSetupDevTenantUsesCompatibleBackendDefault(t *testing.T) {
	t.Setenv("BACKEND_IMAGE", "example/api")
	t.Setenv("FRONTEND_IMAGE", "example/web")
	t.Setenv("APP_IMAGE_VERSION_DEFAULT", "latest")
	t.Setenv("APP_IMAGE_VERSIONS", "v0.0.1")

	s := &server{
		imageTags: func(_ context.Context, _, _ string) (map[string]bool, map[string]bool, error) {
			return map[string]bool{"v0.0.1": true}, map[string]bool{"latest": true}, nil
		},
	}
	sc := scripts.Find("setup-dev-tenant.sh")
	form, err := s.normalizeImageSelection(t.Context(), sc, url.Values{})
	if err != nil {
		t.Fatalf("normalize setup-dev default: %v", err)
	}
	if got := form.Get("tag"); got != "v0.0.1" {
		t.Fatalf("setup-dev default tag = %q, want v0.0.1", got)
	}
}

func mapValues(name, value string) url.Values {
	return url.Values{name: {value}}
}
