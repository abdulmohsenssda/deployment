package scripts

import (
	"os"
	"path/filepath"
	"testing"
)

func TestVersionCatalogUsesExplicitTags(t *testing.T) {
	t.Setenv("BACKEND_IMAGE", "ssdawweq/ifritah-api")
	t.Setenv("FRONTEND_IMAGE", "ssdawweq/ifritah-web")
	t.Setenv("APP_IMAGE_VERSIONS", "v0.0.1,v0.0.2")
	t.Setenv("APP_IMAGE_VERSION_DEFAULT", "v0.0.1")

	releases := VersionCatalog()
	if len(releases) != 2 {
		t.Fatalf("expected 2 releases, got %d", len(releases))
	}
	if releases[0].Tag != "v0.0.1" || releases[0].BackendImage != "ssdawweq/ifritah-api:v0.0.1" {
		t.Fatalf("unexpected first release: %+v", releases[0])
	}
	if releases[1].Broken || releases[1].Status != "not-ready" || releases[1].Ready {
		t.Fatalf("expected v0.0.2 to be visibly not-ready without a manifest, got %+v", releases[1])
	}
}

func TestVersionCatalogRejectsChannelTags(t *testing.T) {
	t.Setenv("APP_IMAGE_VERSIONS", "latest,stable,dev,v0.0.1")

	releases := VersionCatalog()
	if len(releases) != 1 || releases[0].Tag != "v0.0.1" {
		t.Fatalf("expected only semver release tags, got %+v", releases)
	}
}

func TestVersionCatalogCanLoadReleaseFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "releases.json")
	data := `[{"tag":"v0.0.2","status":"ready","title":"Next release","notes":["Release note"]}]`
	if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("APP_IMAGE_RELEASES_FILE", path)
	t.Setenv("APP_IMAGE_VERSION_DEFAULT", "v0.0.2")

	releases := VersionCatalog()
	if len(releases) != 1 || releases[0].Tag != "v0.0.2" {
		t.Fatalf("expected file release, got %+v", releases)
	}
	if releases[0].Title != "Next release" || len(releases[0].Notes) != 1 || releases[0].Ready {
		t.Fatalf("expected release metadata, got %+v", releases[0])
	}
}

func TestDefaultImageVersionUsesSharedDevTagWithoutOverride(t *testing.T) {
	t.Setenv("APP_IMAGE_VERSION_DEFAULT", "")
	t.Setenv("APP_IMAGE_VERSIONS", "v0.0.1")

	if got := DefaultImageVersion(); got != "dev" {
		t.Fatalf("DefaultImageVersion() = %q, want dev", got)
	}
}

func TestDefaultImageVersionUsesDevChannelInDev(t *testing.T) {
	t.Setenv("DASHBOARD_ENV", "dev")
	t.Setenv("APP_IMAGE_VERSION_DEFAULT", "")
	if got := DefaultImageVersion(); got != "dev" {
		t.Fatalf("expected dev default, got %q", got)
	}
}

func TestDefaultImageVersionUsesDevChannelWithoutEnvironmentOverride(t *testing.T) {
	t.Setenv("DASHBOARD_ENV", "prod")
	t.Setenv("APP_IMAGE_VERSION_DEFAULT", "")
	if got := DefaultImageVersion(); got != "dev" {
		t.Fatalf("expected dev default channel, got %q", got)
	}
}

func TestVersionCatalogLoadsIndependentManifestComponents(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "releases.json")
	digest := "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	data := `{"schema_version":1,"releases":[{"id":"v0.0.3","channel":"stable","status":"ready","validation":{"ready":true},"components":{"backend":{"image":"owner/api:v0.0.3","digest":"` + digest + `","version":"v0.0.3","source_commit":"api-sha","repository":"owner/backend","workflow_run":"30","validation":{"tag_exists":true,"oci_identity_valid":true}},"frontend":{"image":"owner/web:v0.0.2","digest":"` + digest + `","version":"v0.0.2","source_commit":"web-sha","repository":"owner/frontend","workflow_run":"31","validation":{"tag_exists":true,"oci_identity_valid":true}}}}]}`
	if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("APP_IMAGE_RELEASES_FILE", path)
	t.Setenv("APP_IMAGE_VERSIONS", "")
	t.Setenv("APP_IMAGE_VERSION_DEFAULT", "")

	releases := VersionCatalog()
	if len(releases) != 1 || !releases[0].Ready {
		t.Fatalf("expected validated manifest release, got %+v", releases)
	}
	if releases[0].BackendVersion != "v0.0.3" || releases[0].FrontendVersion != "v0.0.2" {
		t.Fatalf("expected independent component versions, got %+v", releases[0])
	}
	if releases[0].Channel != "stable" || releases[0].BackendSourceCommit != "api-sha" || releases[0].FrontendDigest != digest {
		t.Fatalf("expected component provenance, got %+v", releases[0])
	}
}

func TestVersionCatalogRejectsMissingComponentIdentity(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "releases.json")
	data := `{"schema_version":1,"releases":[{"id":"v0.0.4","status":"ready","validation":{"ready":true},"components":{"backend":{"image":"owner/api:v0.0.4","digest":"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","version":"v0.0.4","source_commit":"api-sha","repository":"owner/backend","workflow_run":"40","validation":{"tag_exists":true,"oci_identity_valid":true}}}}]}`
	if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("APP_IMAGE_RELEASES_FILE", path)
	t.Setenv("APP_IMAGE_VERSIONS", "")
	t.Setenv("APP_IMAGE_VERSION_DEFAULT", "")

	releases := VersionCatalog()
	if len(releases) != 1 || releases[0].Ready || releases[0].Status != "not-ready" {
		t.Fatalf("expected missing frontend identity to be not-ready, got %+v", releases)
	}
	if !containsString(releases[0].ValidationErrors, "missing frontend component") {
		t.Fatalf("expected missing component reason, got %v", releases[0].ValidationErrors)
	}
}

func containsString(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}
