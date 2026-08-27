package logbuf

import (
	"path/filepath"
	"testing"
)

func TestPersistentStoreReloadsRingBuffer(t *testing.T) {
	dir := t.TempDir()
	store, err := NewPersistent(2, dir)
	if err != nil {
		t.Fatalf("create store: %v", err)
	}
	for _, line := range []string{"one", "two", "three", "four", "five"} {
		if err := store.Append("tenant:acme", line); err != nil {
			t.Fatalf("append %q: %v", line, err)
		}
	}

	reloaded, err := NewPersistent(2, dir)
	if err != nil {
		t.Fatalf("reload store: %v", err)
	}
	entries := reloaded.Snapshot("tenant:acme")
	if len(entries) != 2 {
		t.Fatalf("got %d entries, want 2", len(entries))
	}
	if entries[0].Line != "four" || entries[1].Line != "five" {
		t.Fatalf("got lines %q, %q; want four, five", entries[0].Line, entries[1].Line)
	}
}

func TestPersistentStoreUsesOpaqueKeyFilename(t *testing.T) {
	dir := t.TempDir()
	store, err := NewPersistent(10, dir)
	if err != nil {
		t.Fatalf("create store: %v", err)
	}
	if err := store.Append("activity:tenant:acme/blue", "safe"); err != nil {
		t.Fatalf("append: %v", err)
	}
	files, err := filepath.Glob(filepath.Join(dir, "*.jsonl"))
	if err != nil {
		t.Fatalf("glob: %v", err)
	}
	if len(files) != 1 {
		t.Fatalf("got %d persisted files, want 1", len(files))
	}
}
