// Package main is the entry point for the Dokku admin dashboard.
//
// The dashboard runs on each environment's server (one container per env),
// mounts /var/run/docker.sock and /usr/local/bin/dokku, and exposes a
// password-protected web UI for listing, controlling, and tailing logs of all
// Dokku apps living on that host.
package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/abdul-mohsen/deployment/dashboard/internal/config"
	"github.com/abdul-mohsen/deployment/dashboard/internal/dokku"
	"github.com/abdul-mohsen/deployment/dashboard/internal/logbuf"
	"github.com/abdul-mohsen/deployment/dashboard/internal/retention"
	"github.com/abdul-mohsen/deployment/dashboard/internal/scripts"
	"github.com/abdul-mohsen/deployment/dashboard/internal/web"
)

func main() {
	// Pull MYSQL_*, BASE_DOMAIN, etc. from the deployment env files (same
	// precedence verify-mysql.sh uses: install.env wins over config.env).
	// Environment variables already set in the container (compose / shell)
	// always take precedence over file values.
	depDir := os.Getenv("DEPLOYMENT_DIR")
	if depDir == "" {
		depDir = "/opt/deployment"
	}
	config.LoadEnvFiles(depDir+"/install.env", depDir+"/config.env")

	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	client := dokku.New(cfg.DockerBin, cfg.DokkuContainer)
	store, err := logbuf.NewPersistent(cfg.LogBufferLines, cfg.LogDir)
	if err != nil {
		log.Fatalf("logs: %v", err)
	}
	runner := scripts.NewRunner(cfg.DockerBin, cfg.RunnerImage, cfg.ScriptsHostPath, cfg.ConfigFile)
	if cfg.BackupDir != "" {
		runner.SetBackupDir(cfg.BackupDir)
	}
	if cfg.StorageRoot != "" {
		runner.SetStorageRoot(cfg.StorageRoot)
	}

	// Start the daily backup retention policy. User-origin backups are never
	// pruned by this policy.
	retentionRunner := retention.New(cfg.DockerBin, cfg.RunnerImage, cfg.ScriptsHostPath, cfg.BackupRetentionDays)
	if cfg.BackupDir != "" {
		retentionRunner.SetBackupDir(cfg.BackupDir)
	}
	bgCtx, bgCancel := context.WithCancel(context.Background())
	retentionRunner.Start(bgCtx)

	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           web.Router(cfg, client, store, runner),
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		log.Printf("dashboard env=%s listening on %s", cfg.EnvName, cfg.Listen)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("listen: %v", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop

	bgCancel()
	retentionRunner.Stop()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
}
