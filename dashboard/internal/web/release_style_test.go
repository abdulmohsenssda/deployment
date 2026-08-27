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
		`class="page-header page-hero"`,
		`class="btn btn-primary"`,
		`class="btn btn-secondary"`,
		`class="btn-action good"`,
		`class="btn-action"`,
	} {
		if !strings.Contains(templateText, want) {
			t.Errorf("release template missing style hook %q", want)
		}
	}

	styleText := string(styleBytes)
	for _, want := range []string{
		".page-header {",
		".page-hero {",
		".btn {",
		".btn-action {",
		".btn-action.good",
		"@media (max-width: 768px)",
		".release-grid",
	} {
		if !strings.Contains(styleText, want) {
			t.Errorf("stylesheet missing release style %q", want)
		}
	}
}
