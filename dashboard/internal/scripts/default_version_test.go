package scripts

import (
	"os"
	"path/filepath"
	"testing"
)

// A release catalog that only contains the placeholder v0.0.1 tag must not
// hijack the default image version. In the branch-only automation flow the
// operator expects the rolling "dev" image to be the default unless an explicit
// APP_IMAGE_VERSION_DEFAULT override is configured. Regression test for the
// "details show v0.0.1 instead of the selected dev tag" defect.
func TestDefaultImageVersion_PrefersDevWithoutExplicitOverride(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "releases.json")
	if err := os.WriteFile(path, []byte(`[{"tag":"v0.0.1","status":"ready","title":"Initial release"}]`), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("APP_IMAGE_RELEASES_FILE", path)
	t.Setenv("APP_IMAGE_VERSION_DEFAULT", "")
	t.Setenv("APP_IMAGE_VERSIONS", "")

	if got := DefaultImageVersion(); got != "dev" {
		t.Fatalf("DefaultImageVersion() = %q, want %q (placeholder catalog must not override the dev default)", got, "dev")
	}
}

// An explicit APP_IMAGE_VERSION_DEFAULT still wins so production release
// pinning keeps working.
func TestDefaultImageVersion_ExplicitOverrideWins(t *testing.T) {
	t.Setenv("APP_IMAGE_VERSION_DEFAULT", "v0.0.2")
	t.Setenv("APP_IMAGE_VERSIONS", "v0.0.1,v0.0.2")

	if got := DefaultImageVersion(); got != "v0.0.2" {
		t.Fatalf("DefaultImageVersion() = %q, want %q", got, "v0.0.2")
	}
}
