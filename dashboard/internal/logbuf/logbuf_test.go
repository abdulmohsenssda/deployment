package logbuf

import (
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
