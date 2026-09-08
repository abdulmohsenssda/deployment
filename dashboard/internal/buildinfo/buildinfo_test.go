package buildinfo

import "testing"

func TestCurrentUsesEmbeddedIdentity(t *testing.T) {
	oldVersion, oldCommit := Version, Commit
	t.Cleanup(func() {
		Version, Commit = oldVersion, oldCommit
	})
	for _, name := range []string{
		"APP_IMAGE_VERSION", "APP_VERSION", "APP_IMAGE_COMMIT", "APP_COMMIT",
		"APP_IMAGE_CHANNEL", "APP_BUILD_CHANNEL", "APP_IMAGE_TAG",
		"APP_IMAGE_REF", "APP_IMAGE_DIGEST", "APP_WORKFLOW_RUN_ID",
		"APP_WORKFLOW_RUN_URL", "APP_BUILT_AT",
	} {
		t.Setenv(name, "")
	}
	Version = "main"
	Commit = "0123456789abcdef"

	got := Current()
	if got.Version != "main" || got.Commit != "0123456789abcdef" {
		t.Fatalf("Current() = %+v", got)
	}
	if got.AssetVersion() != Commit {
		t.Fatalf("AssetVersion() = %q, want %q", got.AssetVersion(), Commit)
	}
	if got.String() != "main (0123456789abcdef)" {
		t.Fatalf("String() = %q", got.String())
	}
}

func TestCurrentLoadsRuntimeImageIdentity(t *testing.T) {
	t.Setenv("APP_IMAGE_VERSION", "v1.2.3")
	t.Setenv("APP_IMAGE_COMMIT", "0123456789abcdef")
	t.Setenv("APP_IMAGE_CHANNEL", "production")
	t.Setenv("APP_IMAGE_REF", "ssdawweq/dokku-dashboard:prod")
	t.Setenv("APP_IMAGE_DIGEST", "sha256:abcdef")
	t.Setenv("APP_WORKFLOW_RUN_ID", "12345")
	t.Setenv("APP_WORKFLOW_RUN_URL", "https://github.com/example/repo/actions/runs/12345")
	t.Setenv("APP_BUILT_AT", "2026-01-01T00:00:00Z")

	got := Current()
	if got.Version != "v1.2.3" || got.SemanticVersion != "v1.2.3" ||
		got.Commit != "0123456789abcdef" ||
		got.ShortCommit != "0123456" || got.CommitShort != "0123456" || got.Channel != "production" ||
		got.Tag != "prod" || got.Ref != "ssdawweq/dokku-dashboard:prod" ||
		got.ImageRef != got.Ref || got.Digest != "sha256:abcdef" ||
		got.WorkflowRunID != "12345" || got.WorkflowRunURL == "" ||
		got.BuiltAt != "2026-01-01T00:00:00Z" {
		t.Fatalf("Current() = %+v", got)
	}
}

func TestCurrentRejectsUnsafeIdentityValues(t *testing.T) {
	oldVersion, oldCommit := Version, Commit
	t.Cleanup(func() {
		Version, Commit = oldVersion, oldCommit
	})
	for _, name := range []string{"APP_IMAGE_VERSION", "APP_IMAGE_COMMIT"} {
		t.Setenv(name, "")
	}
	Version = "v1.2.3\nsecret"
	Commit = ""

	got := Current()
	if got.Version != "dev" {
		t.Fatalf("unsafe version = %q, want dev", got.Version)
	}
	if got.Commit != "unknown" {
		t.Fatalf("empty commit = %q, want unknown", got.Commit)
	}

	Version = `release"onmouseover="alert(1)`
	if got := Current().Version; got != "dev" {
		t.Fatalf("unsafe punctuation version = %q, want dev", got)
	}
}
