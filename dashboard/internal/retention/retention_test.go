package retention

import (
	"slices"
	"testing"
)

func TestDockerArgsMountBackupDirectory(t *testing.T) {
	r := New("docker", "runner:latest", "/opt/deployment", 14)
	r.SetBackupDir("/opt/tenant-backups")

	args := r.dockerArgs("/var/run/docker.sock:/var/run/docker.sock")
	if !slices.Contains(args, "-e") || !slices.Contains(args, "BACKUP_DIR=/opt/tenant-backups") {
		t.Fatalf("retention args do not pass BACKUP_DIR: %v", args)
	}
	if !slices.Contains(args, "/opt/tenant-backups:/opt/tenant-backups") {
		t.Fatalf("retention args do not mount backup directory: %v", args)
	}
}

func TestDockerArgsOmitBackupMountWhenUnset(t *testing.T) {
	r := New("docker", "runner:latest", "/opt/deployment", 30)

	args := r.dockerArgs("/var/run/docker.sock:/var/run/docker.sock")
	if slices.Contains(args, "BACKUP_DIR=/opt/tenant-backups") {
		t.Fatalf("unset backup directory unexpectedly added to args: %v", args)
	}
}
