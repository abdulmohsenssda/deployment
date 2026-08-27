package logbuf

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestAppendStripsTerminalControls(t *testing.T) {
	store := New(10)
	store.Append("api", "\x1b[31mfailed\x1b[0m \x1b[2K")

	entries := store.Snapshot("api")
	if len(entries) != 1 {
		t.Fatalf("Snapshot() returned %d entries, want 1", len(entries))
	}
	if got, want := entries[0].Line, "failed "; got != want {
		t.Fatalf("stored line = %q, want %q", got, want)
	}

	if got := store.Dump("api"); strings.ContainsAny(got, "\x1b\x00\x07") {
		t.Fatalf("Dump() contains terminal controls: %q", got)
	}
}

func TestAppendPreservesMultilineText(t *testing.T) {
	store := New(10)
	store.Append("api", "first\n\x1b[32msecond\x1b[0m\nthird")

	entries := store.Snapshot("api")
	if got, want := entries[0].Line, "first\nsecond\nthird"; got != want {
		t.Fatalf("stored multiline line = %q, want %q", got, want)
	}
	dump := store.Dump("api")
	if !strings.Contains(dump, " first\nsecond\nthird\n") {
		t.Fatalf("Dump() lost multiline text: %q", dump)
	}
	if strings.ContainsAny(dump, "\x1b\x00\x07") {
		t.Fatalf("Dump() contains terminal controls: %q", dump)
	}
}

func TestPersistentStoreReloadsRingBuffer(t *testing.T) {
	dir := t.TempDir()
	store, err := NewPersistent(2, dir)
	if err != nil {
		t.Fatalf("create store: %v", err)
	}
	for _, line := range []string{"one", "two", "three", "four", "five"} {
		if err := store.Append("activity:tenant:acme", line); err != nil {
			t.Fatalf("append %q: %v", line, err)
		}
	}

	reloaded, err := NewPersistent(2, dir)
	if err != nil {
		t.Fatalf("reload store: %v", err)
	}
	entries := reloaded.Snapshot("activity:tenant:acme")
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
	if err := store.Append("activity:app:acme/blue", "safe"); err != nil {
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
