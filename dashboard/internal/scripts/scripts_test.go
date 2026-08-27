package scripts

import (
	"slices"
	"testing"
)

func TestDockerArgsMountPersistentStorage(t *testing.T) {
	r := NewRunner("docker", "runner:latest", "/opt/deployment", "")
	r.SetBackupDir("/opt/tenant-backups")
	r.SetStorageRoot("/opt/tenant-data")

	args := r.dockerArgs("/var/run/docker.sock:/var/run/docker.sock")
	if !slices.Contains(args, "-e") ||
		!slices.Contains(args, "STORAGE_ROOT=/opt/tenant-data") {
		t.Fatalf("runner args do not pass STORAGE_ROOT: %v", args)
	}
	if !slices.Contains(args, "/opt/tenant-data:/opt/tenant-data") {
		t.Fatalf("runner args do not mount persistent storage: %v", args)
	}
}

func TestDockerArgsOmitPersistentStorageWhenUnset(t *testing.T) {
	r := NewRunner("docker", "runner:latest", "/opt/deployment", "")

	args := r.dockerArgs("/var/run/docker.sock:/var/run/docker.sock")
	if slices.Contains(args, "STORAGE_ROOT=/opt/tenant-data") {
		t.Fatalf("unset storage root unexpectedly added to args: %v", args)
	}
}
