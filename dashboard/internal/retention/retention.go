// Package retention runs the backup retention policy on a schedule.
//
// Policy:
//   - Auto-origin backups older than RetentionDays (default 30) are pruned.
//   - User-origin backups are never auto-deleted by this policy.
//   - User-origin backups are capped at MaxUserBackups (default 50) per tenant;
//     a warning is logged when the limit is reached (deletion is the user's job).
//
// The policy runs via the existing manage-backups.sh prune command which
// already understands origin=auto pruning.
package retention

import (
	"context"
	"log"
	"os"
	"os/exec"
	"strconv"
	"time"
)

const (
	DefaultRetentionDays = 30
	MaxUserBackups       = 50
)

// Runner executes the retention policy on a schedule.
type Runner struct {
	dockerBin       string
	runnerImage     string
	scriptsHostPath string
	backupDir       string
	retentionDays   int
	stop            chan struct{}
}

// New creates a retention runner. Call Start to begin the schedule.
func New(dockerBin, runnerImage, scriptsHostPath string, retentionDays int) *Runner {
	if retentionDays <= 0 {
		retentionDays = DefaultRetentionDays
	}
	return &Runner{
		dockerBin:       dockerBin,
		runnerImage:     runnerImage,
		scriptsHostPath: scriptsHostPath,
		retentionDays:   retentionDays,
		stop:            make(chan struct{}),
	}
}

// SetBackupDir configures the host backup directory mounted into retention
// sidecars so pruning operates on persisted artifacts.
func (r *Runner) SetBackupDir(dir string) {
	r.backupDir = dir
}

// Start begins the daily retention run. Call Stop to shut it down cleanly.
func (r *Runner) Start(ctx context.Context) {
	go func() {
		// Run once at startup, then every 24 hours.
		r.run(ctx)
		ticker := time.NewTicker(24 * time.Hour)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				r.run(ctx)
			case <-r.stop:
				return
			case <-ctx.Done():
				return
			}
		}
	}()
}

// Stop shuts down the retention runner gracefully.
func (r *Runner) Stop() {
	select {
	case <-r.stop: // already closed
	default:
		close(r.stop)
	}
}

func (r *Runner) dockerArgs(dockerSocket string) []string {
	bashScript := `set -e
mkdir -p /tmp/dep-ret
cp -r /opt/deployment/scripts /tmp/dep-ret/
[ -f /opt/deployment/config.env ] && cp /opt/deployment/config.env /tmp/dep-ret/ || true
find /tmp/dep-ret -name '*.sh' -exec sed -i 's/\r$//' {} +
cd /tmp/dep-ret
exec bash scripts/manage-backups.sh prune --retention-days "$1"`

	args := []string{
		"run", "--rm", "-i",
		"-v", dockerSocket,
		"-v", r.scriptsHostPath + ":/opt/deployment:ro",
		"--network", "host",
	}
	if r.backupDir != "" {
		args = append(args, "-v", r.backupDir+":"+r.backupDir, "-e", "BACKUP_DIR="+r.backupDir)
	}
	return append(args,
		r.runnerImage,
		"bash", "-c", bashScript,
		"--", strconv.Itoa(r.retentionDays),
	)
}

// run executes manage-backups.sh prune --retention-days N.
func (r *Runner) run(ctx context.Context) {
	if r.scriptsHostPath == "" {
		log.Println("[retention] SCRIPTS_HOST_PATH not set — skipping")
		return
	}
	log.Printf("[retention] running auto-backup prune (retention=%d days)", r.retentionDays)

	dockerSocket := "/var/run/docker.sock:/var/run/docker.sock"
	if _, err := os.Stat(`\\.\pipe\dockerDesktopLinuxEngine`); err == nil {
		dockerSocket = `//./pipe/dockerDesktopLinuxEngine://./pipe/dockerDesktopLinuxEngine`
	} else if _, err := os.Stat(`\\.\pipe\docker_engine`); err == nil {
		dockerSocket = `//./pipe/docker_engine://./pipe/docker_engine`
	}

	runCtx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()

	cmd := exec.CommandContext(runCtx, r.dockerBin, r.dockerArgs(dockerSocket)...)
	cmd.Env = append(os.Environ(), "TERM=dumb")
	out, err := cmd.CombinedOutput()
	if err != nil {
		log.Printf("[retention] prune error: %v\noutput: %s", err, out)
	} else {
		log.Printf("[retention] prune complete\noutput: %s", out)
	}
}
