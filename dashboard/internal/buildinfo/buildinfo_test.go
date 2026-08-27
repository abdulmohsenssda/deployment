package buildinfo

import "testing"

func TestCurrentUsesEmbeddedIdentity(t *testing.T) {
	oldVersion, oldCommit := Version, Commit
	t.Cleanup(func() {
		Version, Commit = oldVersion, oldCommit
	})
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

func TestCurrentRejectsUnsafeIdentityValues(t *testing.T) {
	oldVersion, oldCommit := Version, Commit
	t.Cleanup(func() {
		Version, Commit = oldVersion, oldCommit
	})
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
