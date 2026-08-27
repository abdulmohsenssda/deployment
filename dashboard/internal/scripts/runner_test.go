package scripts

import (
	"slices"
	"testing"
)

func TestRunnerMountsPersistentTenantDirectories(t *testing.T) {
	r := NewRunner("docker", "runner:latest", "/opt/deployment", "")
	r.SetBackupDir("/opt/tenant-backups")
	r.SetStorageRoot("/opt/tenant-data")

	args := r.volumeArgs()
	for _, want := range []string{
		"-v", "/opt/tenant-backups:/opt/tenant-backups",
		"-e", "BACKUP_DIR=/opt/tenant-backups",
		"-v", "/opt/tenant-data:/opt/tenant-data",
		"-e", "STORAGE_ROOT=/opt/tenant-data",
	} {
		if !slices.Contains(args, want) {
			t.Errorf("runner volume args missing %q: %v", want, args)
		}
	}
}
