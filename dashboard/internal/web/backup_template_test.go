package web

import (
	"strings"
	"testing"
)

func TestTenantBackupTemplateKeepsHistoryControlsReachable(t *testing.T) {
	data, err := tplFS.ReadFile("templates/tenant.html")
	if err != nil {
		t.Fatalf("read tenant template: %v", err)
	}
	template := string(data)

	for _, want := range []string{
		`class="panel backup-panel"`,
		`id="backup-search"`,
		`id="backup-label"`,
		`Search history`,
		`Label new backup`,
		`id="create-backup-btn"`,
		`aria-label="Tenant backup history"`,
		`scope="col"`,
		`data-label="Backup ID"`,
		`data-label="Verified"`,
		`data-label="Actions"`,
		`data-verify="${b.id}"`,
		`data-restore="${b.id}"`,
		`/download"`,
		`data-del="${b.id}"`,
		`confirm('Permanently delete backup`,
		`id="restore-modal"`,
	} {
		if !strings.Contains(template, want) {
			t.Errorf("tenant template missing %q", want)
		}
	}
}

func TestTenantBackupTemplateFiltersHistoryWithoutDroppingActions(t *testing.T) {
	data, err := tplFS.ReadFile("templates/tenant.html")
	if err != nil {
		t.Fatalf("read tenant template: %v", err)
	}
	template := string(data)

	for _, want := range []string{
		`function backupSearchText(backup)`,
		`backupItems.filter`,
		`backupSearch?.addEventListener('input', renderBackups)`,
		`await loadBackups();`,
		`loadBackups();`,
	} {
		if !strings.Contains(template, want) {
			t.Errorf("backup template missing %q", want)
		}
	}
}

func TestBackupStylesReflowHistoryAtMobileWidths(t *testing.T) {
	data, err := staticFS.ReadFile("static/app.css")
	if err != nil {
		t.Fatalf("read app stylesheet: %v", err)
	}
	css := strings.ReplaceAll(string(data), "\r\n", "\n")
	_, mobile, ok := strings.Cut(css, "@media (max-width: 768px) {\n  .backup-panel")
	if !ok {
		t.Fatal("backup mobile media query is missing")
	}
	if !strings.Contains(css, `.backup-panel .btn-action:focus-visible`) {
		t.Error("backup controls are missing a visible keyboard focus style")
	}

	for _, want := range []string{
		`.backup-table-wrap {`,
		`.backup-table {`,
		`.backup-table tbody > tr {`,
		`.backup-table tbody > tr > td::before {`,
		`content: attr(data-label);`,
		`.backup-table .backup-actions .btn-action {`,
		`overflow: visible;`,
		`grid-template-columns: 1fr;`,
	} {
		if !strings.Contains(mobile, want) {
			t.Errorf("mobile backup styles missing %q", want)
		}
	}
}
