# Multi-Tenant Deployment

Server-side automation for a Dokku-based multi-tenant platform.

The primary operator entrypoint is now one git-style command:

```bash
sudo ./scripts/deployctl.sh <area> <command> [args]
```

Use `--plan` to see the underlying script before running it:

```bash
./scripts/deployctl.sh --plan tenant update acme --restart
# bash scripts/update-tenant.sh acme --restart
```

**Two repos own their own build:**

```
backend repo  →  push to dev  ──────────┐
frontend repo →  push to dev  ──────────┤       Docker Hub
                 push to main ────┐     │
                                  ▼     ▼
        myuser/ifritah-api:<tag>  myuser/ifritah-web:<tag>
                                  │                   │
              │ manual            │ webhook/dev deploy
                                  ▼                   ▼
          deployctl fleet sync   deployctl tenant update
                                  │                   │
                              prod tenants       dev tenant
```

- **Dev**: a single tenant; the `dev` branch publishes the shared `:dev` tag
  and webhook deployment can also pull the exact `VERSION` tag.
- **Prod**: ops runs `deploy-all.sh <image> --tenant <client>` per client when promoting a build.
- **App repos own**: Dockerfile, docker-compose for local dev, `.env.example`, and the GitHub Actions workflow that builds + pushes the image.
- **This repo owns**: server provisioning, tenant lifecycle, image polling, manual rollouts, backups, rollbacks.

## Repo layout

```
.gitignore
config.env.example          # copy to config.env on each server
README.md
scripts/                    # ops automation (run on the server)
  deployctl.sh              # one command: tenant/fleet/stack/setup/db/dokku/webhook
  setup.sh                  # one-time install: Dokku, MySQL wiring, cron, webhook
  setup-dev-tenant.sh       # creates the single dev tenant pinned to DEV_TAG
  create-tenant.sh          # provision a new prod tenant
  remove-tenant.sh
  update-tenant.sh
  deploy-all.sh             # MANUAL prod deploy (per-client or all)
  auto-pull.sh              # optional cron: dev-only auto-deploy from DEV_TAG
  rollback-tenant.sh
  set-tenant-image.sh       # pin a tenant to a specific image
  list-tenants.sh
  tail-logs.sh
  backup-tenant.sh
  cleanup-old-files.sh
  webhook-server.sh         # optional: instant dev deploy on push
  webhook-tls.sh            # TLS in front of webhook
  webhook-deploy.service    # systemd unit
  Dockerfile.webhook
  lib.sh                    # shared helpers
templates/                  # COPY these into your backend / frontend repos
  README.md
  backend/
    Dockerfile
    docker-compose.yml
    .env.example
    .dockerignore
    .gitignore
    .github/workflows/deploy.yml
  frontend/
    Dockerfile
    docker-compose.yml
    .env.example
    .dockerignore
    .gitignore
    .github/workflows/deploy.yml
```

## Server prerequisites

- Linux + Docker Engine
- MySQL on the host (or reachable via `host.docker.internal`)
- Wildcard DNS: `*.app.example.com → server IP`

## Initial setup

```bash
git clone <this-repo> /opt/deployment
cd /opt/deployment
cp config.env.example config.env
$EDITOR config.env

sudo ./scripts/setup.sh
sudo ./scripts/deployctl.sh setup dev-tenant        # creates the one dev tenant
```

## Day-2 operations

| Task | Command |
|---|---|
| Create prod tenant | `sudo ./scripts/deployctl.sh tenant create acme` |
| Manual prod deploy (one client) | `sudo ./scripts/deployctl.sh fleet sync myuser/ifritah-api:v0.0.1 --tenant acme` |
| Manual prod deploy (all clients) | `sudo ./scripts/deployctl.sh fleet sync myuser/ifritah-api:v0.0.1` |
| Pin a tenant to a fixed image | `sudo ./scripts/deployctl.sh tenant pin acme --backend myuser/ifritah-api:v0.0.1` |
| Rollback | `sudo ./scripts/deployctl.sh tenant rollback acme --to myuser/ifritah-api:abc1234` |
| List tenants | `sudo ./scripts/deployctl.sh tenant list` |
| Tenant status | `sudo ./scripts/deployctl.sh tenant status acme` |
| Tail logs | `sudo ./scripts/deployctl.sh tenant logs acme --type backend` |
| Backup | `sudo ./scripts/deployctl.sh fleet backup` |
| Backup (user, protected) | `sudo ./scripts/deployctl.sh tenant backup acme --origin user --owner alice` |
| List backups | `sudo ./scripts/deployctl.sh tenant backups list acme` |
| Delete own backup | `sudo ./scripts/deployctl.sh tenant backups delete acme_20250101_120000 --owner alice` |
| Prune by policy | `sudo ./scripts/deployctl.sh fleet backups prune` |
| Restore / rollback | `sudo ./scripts/deployctl.sh tenant restore acme --from acme_20250101_120000` |
| Restart platform | `sudo ./scripts/deployctl.sh stack restart --env all` |

The old `scripts/*.sh` files remain as readable implementation units and compatibility entrypoints. New operations should be exposed through `deployctl.sh` first.

## Backups, restore & rollback

Every backup is a *set*: a manifest sidecar `<tenant>_<timestamp>.meta.json`
plus its `.tar.gz` (files) and `.sql.gz` (database) artifacts in `BACKUP_DIR`.
The manifest records the **origin**, **owner**, optional user **label**, and
whether the artifacts passed integrity verification (`gzip -t`, `tar -tzf`,
non-empty dump).

- **User backups** (`--origin user`) are protected: the retention policy never
  deletes them. Only the owner (or an operator with `--force`) can delete one.
- **Automatic backups** (`--origin auto`, the default) are retained for
  `BACKUP_RETENTION_DAYS` (default 30) and then pruned by policy.
- **Automatic deploys create a verified backup first.** `auto-pull.sh` takes a
  `--require-verified` backup before redeploying; if it can't be verified the
  deploy is skipped and retried next cycle. Opt out with
  `AUTO_BACKUP_BEFORE_REDEPLOY=0` (not recommended).
- **Auto-redeploy can be disabled per environment/tenant** by listing tenant
  names in `AUTO_REDEPLOY_DISABLED` or by unchecking the dashboard toggle.
  The dashboard writes `${TENANT_STATE_DIR:-/opt/tenant-state}/<tenant>.json`;
  this directory must be shared with the host poller.
- **Restore/rollback to any version** with `tenant restore <name> --from <id>`.
  It refuses corrupt backups and, by default, takes a fresh verified safety
  backup of the current state first so the restore itself is reversible.

Backups are managed only through the allow-listed `manage-backups.sh` /
`restore-tenant.sh` scripts (surfaced in the dashboard Scripts page). There is
no arbitrary shell surface.

## Bootstrapping the app repos

```bash
# In the backend repo:
cp -r /opt/deployment/templates/backend/. .
cp .env.example .env       # local dev only — never commit
docker compose up          # local dev stack

# In the frontend repo: same with templates/frontend
```

Each app repo CI reads `VERSION`, validates strict `vMAJOR.MINOR.PATCH`, and builds:
- `:vX.X.X` from `VERSION` → primary deploy tag. Re-running CI with the same version overwrites that tag.
- `:<sha>` on every push → immutable reference for rollbacks/debugging.

Backend and frontend releases must use the same `VERSION` value. The dashboard version picker deploys that one tag to both apps. CI fails if `VERSION` is lower than the latest GitHub Release tag; equal is allowed for overwrite builds.

Each app repo also ships a **PR branch-image workflow**
(`.github/workflows/qa-branch-image.yml`, templated in
`templates/{backend,frontend}/.github/workflows/qa-branch-image.yml`). On every
same-repository pull request it builds and pushes two tags to the configured
Docker Hub repo:

- `:pr-<branch-name>` — a safe, branch-derived mutable tag (always the latest
  build for that branch), and
- `:pr-<branch-name>-<shortsha>` — an immutable per-commit reference.

The dashboard's searchable image selector lists these tags straight from Docker
Hub for the configured account, showing only tags present in **both** the
backend and frontend repos so a branch build is only offered when both apps
have a matching image.

The regular deploy workflow also publishes the mutable `:dev` alias whenever
the source branch is `dev`, alongside the immutable commit-SHA tag. This keeps
the poller and dashboard's default development selection aligned across both
app repositories.

Dashboard images embed a non-secret build version and commit identity. The
published image exposes it through `/version`, the dashboard footer, and
`/healthz` response headers; its embedded web-bundle digest covers templates and
static assets so mixed UI bundles can be detected before publication.

## GitHub secrets to set in each app repo

| Secret | Required | Notes |
|---|---|---|
| `DOCKERHUB_USERNAME` | yes | |
| `DOCKERHUB_TOKEN` | yes | Docker Hub access token |
| `WEBHOOK_URL_DEV` | optional | for instant dev deploy |
| `WEBHOOK_SECRET` | optional | must match `WEBHOOK_SECRET` in `config.env` |

Polling (cron + `auto-pull.sh`) is the safety net and works without any webhook.
