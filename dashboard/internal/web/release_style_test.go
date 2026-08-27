package web

import (
	"strings"
	"testing"
)

func TestReleasePageUsesDefinedStyleHooks(t *testing.T) {
	templateBytes, err := tplFS.ReadFile("templates/releases.html")
	if err != nil {
		t.Fatalf("read release template: %v", err)
	}
	styleBytes, err := staticFS.ReadFile("static/app.css")
	if err != nil {
		t.Fatalf("read stylesheet: %v", err)
	}

	templateText := string(templateBytes)
	for _, want := range []string{
		`class="ops-hero compact"`,
		`class="hero-actions"`,
		`class="command-link"`,
		`class="command-link secondary"`,
		`class="action-chip good"`,
		`class="action-chip"`,
	} {
		if !strings.Contains(templateText, want) {
			t.Errorf("release template missing style hook %q", want)
		}
	}

	styleText := string(styleBytes)
	for _, want := range []string{
		".ops-hero {",
		".hero-actions {",
		".command-link {",
		".command-link.danger {",
		".action-chip {",
		".action-chip.good {",
		".action-chip.danger {",
		".command-link:focus-visible",
		".action-chip:focus-visible",
		"@media (max-width: 768px)",
		".release-actions .action-chip",
	} {
		if !strings.Contains(styleText, want) {
			t.Errorf("stylesheet missing release style %q", want)
		}
	}
}
