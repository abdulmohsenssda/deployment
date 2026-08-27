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
	if releases[1].Broken || releases[1].Status != "ready" {
		t.Fatalf("expected v0.0.2 to be ready, got %+v", releases[1])
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
	if releases[0].Title != "Next release" || len(releases[0].Notes) != 1 {
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
