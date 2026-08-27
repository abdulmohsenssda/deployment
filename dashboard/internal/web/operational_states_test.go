package web

import (
	"strings"
	"testing"
)

func TestOperationalStatePanelsExposeIdleAndEmptyStates(t *testing.T) {
	tests := []struct {
		template string
		panel    string
		empty    string
	}{
		{
			template: "templates/script.html",
			panel:    `id="command-output" class="panel operation-panel" data-state="idle"`,
			empty:    "No command output yet. Run this command to see results.",
		},
		{
			template: "templates/tenant.html",
			panel:    `id="tenant-activity-panel" class="panel activity-panel operation-panel" data-state="idle"`,
			empty:    "No tenant activity yet. Run an action to see results.",
		},
	}

	for _, tc := range tests {
		t.Run(tc.template, func(t *testing.T) {
			source, err := tplFS.ReadFile(tc.template)
			if err != nil {
				t.Fatalf("read template: %v", err)
			}
			text := string(source)
			if !strings.Contains(text, tc.panel) {
				t.Errorf("template does not expose idle operation panel %q", tc.panel)
			}
			if !strings.Contains(text, tc.empty) {
				t.Errorf("template does not expose empty-state text %q", tc.empty)
			}
			for _, state := range []string{"idle", "running", "success", "failure"} {
				if !strings.Contains(text, `operation-status-`+state) &&
					!strings.Contains(text, `'`+state+`'`) &&
					!strings.Contains(text, `"`+state+`"`) {
					t.Errorf("template does not reference %s state", state)
				}
			}
		})
	}
}

func TestOperationStateHelperDefinesExplicitStatesAndPersistence(t *testing.T) {
	source, err := staticFS.ReadFile("static/operation-state.js")
	if err != nil {
		t.Fatalf("read operation-state helper: %v", err)
	}
	text := string(source)
	for _, state := range []string{"idle", "running", "success", "failure"} {
		if !strings.Contains(text, state) {
			t.Errorf("operation-state helper does not define %s", state)
		}
	}
	for _, symbol := range []string{"recoveredState", "createStore", "localStorage"} {
		if !strings.Contains(text, symbol) {
			t.Errorf("operation-state helper missing %s support", symbol)
		}
	}
}
