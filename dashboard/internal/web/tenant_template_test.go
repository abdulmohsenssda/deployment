package web

import (
	"bytes"
	"html/template"
	"strings"
	"testing"
	"time"
)

func renderTenantTemplateForTest(t *testing.T) string {
	t.Helper()

	funcs := template.FuncMap{
		"join":     strings.Join,
		"now":      func() string { return time.Now().Format("2006-01-02 15:04:05") },
		"stateClr": stateClass,
		"httpClr":  httpClass,
		"json":     templateJSON,
	}
	page, err := template.New("").Funcs(funcs).ParseFS(
		tplFS,
		"templates/_layout.html",
		"templates/palette.html",
		"templates/tenant.html",
	)
	if err != nil {
		t.Fatalf("parse tenant template: %v", err)
	}

	var out bytes.Buffer
	data := map[string]any{
		"Env":            "test",
		"Tenant":         "acme",
		"DefaultVersion": "dev",
		"AutoRedeploy":   false,
		"MaxUserBackups": 3,
	}
	if err := page.ExecuteTemplate(&out, "tenant.html", data); err != nil {
		t.Fatalf("execute tenant template: %v", err)
	}
	return out.String()
}

func inputTagByID(t *testing.T, markup, id string) string {
	t.Helper()

	for offset := 0; offset < len(markup); {
		relativeStart := strings.Index(markup[offset:], "<input")
		if relativeStart < 0 {
			break
		}
		start := offset + relativeStart
		relativeEnd := strings.Index(markup[start:], ">")
		if relativeEnd < 0 {
			break
		}
		end := start + relativeEnd + 1
		tag := markup[start:end]
		if strings.Contains(tag, `id="`+id+`"`) {
			return tag
		}
		offset = end
	}
	t.Fatalf("input with id %q not found", id)
	return ""
}

func TestTenantCredentialInputsHaveStableNamesAndAccessibleMetadata(t *testing.T) {
	markup := renderTenantTemplateForTest(t)
	fields := []struct {
		role        string
		id          string
		name        string
		helpID      string
		messageID   string
		describedBy string
	}{
		{
			role: "admin", id: "cred-admin-pass", name: "admin_password",
			helpID: "cred-admin-pass-help", messageID: "cred-admin-msg",
			describedBy: "cred-admin-pass-help cred-admin-msg",
		},
		{
			role: "manager", id: "cred-manager-pass", name: "manager_password",
			helpID: "cred-manager-pass-help", messageID: "cred-manager-msg",
			describedBy: "cred-manager-pass-help cred-manager-msg",
		},
	}

	for _, field := range fields {
		t.Run(field.role, func(t *testing.T) {
			input := inputTagByID(t, markup, field.id)
			for _, attribute := range []string{
				`name="` + field.name + `"`,
				`type="password"`,
				`autocomplete="new-password"`,
				`minlength="8"`,
				`aria-describedby="` + field.describedBy + `"`,
			} {
				if !strings.Contains(input, attribute) {
					t.Errorf("input %s missing %s: %s", field.id, attribute, input)
				}
			}
			if !strings.Contains(input, " required") {
				t.Errorf("input %s is not required: %s", field.id, input)
			}
			if !strings.Contains(markup, `<label for="`+field.id+`"`) {
				t.Errorf("input %s has no associated label", field.id)
			}
			for _, descriptionID := range []string{field.helpID, field.messageID} {
				if !strings.Contains(markup, `id="`+descriptionID+`"`) {
					t.Errorf("input %s references missing description %s", field.id, descriptionID)
				}
			}
			status := `<div id="` + field.messageID + `" role="status" aria-live="polite" aria-atomic="true"`
			if !strings.Contains(markup, status) {
				t.Errorf("credential status %s is not an accessible live region", field.messageID)
			}
		})
	}
}

func TestTenantCredentialMutationHookKeepsRoleAndValidationContract(t *testing.T) {
	markup := renderTenantTemplateForTest(t)

	for _, role := range []string{"admin", "manager"} {
		if !strings.Contains(markup, `id="cred-`+role+`-btn" data-role="`+role+`"`) {
			t.Errorf("%s credential button no longer identifies its role", role)
		}
		if !strings.Contains(markup, "setupCredBtn('"+role+"')") {
			t.Errorf("%s credential button is not wired to the mutation handler", role)
		}
	}
	for _, snippet := range []string{
		"if (pw.length < 8)",
		"body: 'role=' + role + '&new_password=' + encodeURIComponent(pw)",
	} {
		if !strings.Contains(markup, snippet) {
			t.Errorf("credential mutation contract missing %q", snippet)
		}
	}
}
