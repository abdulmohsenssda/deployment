# Dokku Control Plane

Argo-CD-inspired web UI for the Dokku tenants on this server.

- Application grid with Health, Sync, Live, and Desired state
- Per-app actions: start / stop / restart / rebuild
- Tenant-first actions: select a tenant, then update version / restart / stop / delete
- Compatible version picker: one release tag maps to backend and frontend images
- Release notes page with broken-version status
- Live log streaming (SSE) + persistent ring-buffer log aggregation +
  downloadable dump
- Durable activity history for tenant, app, and command operations
- Command forms backed by `scripts/deployctl.sh` with streamed output
- Command palette (Ctrl/Cmd+K)
- Single-admin login (bcrypt) with signed cookie session

## Deployment model

One container per environment (dev box, prod box). The container mounts
`/var/run/docker.sock` and shells out via `docker exec dokku dokku ...`, so
no SSH keys, no Dokku CLI install inside the dashboard image, no extra
runtime besides the docker socket.

## Configuration

| Var                   | Required | Default         |
| --------------------- | -------- | --------------- |
| `ADMIN_USER`          | yes      | —               |
| `ADMIN_PASSWORD_HASH` | yes      | — (bcrypt)      |
| `DASHBOARD_ENV`       | no       | `dev`           |
| `LISTEN`              | no       | `:8080`         |
| `DOCKER_BIN`          | no       | `docker`        |
| `DOKKU_CONTAINER`     | no       | `dokku`         |
| `BASE_DOMAIN`         | no       | `localhost`     |
| `SESSION_KEY`         | no       | random per boot |
| `LOG_BUFFER_LINES`    | no       | `2000`          |
| `LOG_DIR`             | no       | `/opt/dashboard-logs` |
| `COOKIE_SECURE`       | no       | `false`         |
| `DASHBOARD_SNAPSHOT_WORKERS` | no | `8`             |
| `DASHBOARD_ENV_FILE`  | no       | —               |
| `TENANT_NAME_PREFIX`  | no       | —               |
| `STORAGE_ROOT`        | no       | `/opt/tenant-data` |
| `MYSQL_HOST`          | no       | `127.0.0.1`   |
| `MYSQL_PORT`          | no       | `3306`        |
| `MYSQL_ROOT_USER`     | no       | `root`        |
| `MYSQL_ROOT_PASSWORD` | no       | —             |

The image picker accepts exact SemVer releases and branch/channel tags such as
`dev`, `latest`, or a PR branch tag. Tags are discovered from the configured
Docker Hub backend and frontend repositories, and the dashboard marks whether
each tag exists in both repositories before it is deployed to both apps:

```sh
BACKEND_IMAGE=ssdawweq/ifritah-api
FRONTEND_IMAGE=ssdawweq/ifritah-web
APP_IMAGE_VERSIONS=v0.0.1
APP_IMAGE_VERSION_DEFAULT=dev
```

The tenant details page reads the deployed `APP_IMAGE_VERSION` from the
running app, so the Sync form remains on the selected tag instead of falling
back to a catalog placeholder. Use `TENANT_NAME_PREFIX` when dev and prod
dashboards share one server or MySQL. With `TENANT_NAME_PREFIX=dev-`, creating
tenant `acme` creates Dokku apps `dev-acme-backend` /
`dev-acme-frontend` and database `tenant_dev_acme`. Use
`TENANT_NAME_PREFIX=prod-` for prod so prod creates `tenant_prod_acme` instead.
For two dashboards on one server, set this in each dashboard's
`dashboard.env`; keep the shared `config.env` prefix unset or point each
dashboard at a matching `DEPLOY_CONFIG_FILE`.

`LOG_DIR` is a persistent, writable directory mounted by both Compose
profiles. The dashboard stores application log lines and recent operation
activity as private JSONL files there, then reloads them on startup. Keep this
directory on durable server storage and include it in the server backup policy.
`STORAGE_ROOT` is mounted into script runner sidecars so user-created and
automatic backups include tenant persistent files. Set the `MYSQL_*` values in
the dashboard environment when SQL backups or accounting exports are enabled.

Publishing `BACKEND_IMAGE:v0.0.1` and `FRONTEND_IMAGE:v0.0.1` makes `v0.0.1` selectable as a compatible pair. Re-pushing without changing `VERSION` overwrites that same image tag; increment `VERSION` only for a new feature or bug-fix release.

Release notes are best kept in GitHub Releases, then mirrored into `dashboard/releases.json` for the server dashboard, or into `APP_IMAGE_RELEASES_FILE` when set. Broken status is not read from the file: the dashboard marks a version broken when the latest Dokku deployment currently running that version is not healthy. The file shape is:

```json
[
  {
    "tag": "vX.X.X",
    "date": "YYYY-MM-DD",
    "status": "ready",
    "title": "Short release title",
    "notes": ["Human-written release note."]
  }
]
```

The equivalent shell workflow uses the same command vocabulary:

```sh
sudo ./scripts/deployctl.sh tenant status acme
sudo ./scripts/deployctl.sh tenant update acme --backend-image repo/ifritah-api:v0.0.1 --frontend-image repo/ifritah-web:v0.0.1
sudo ./scripts/deployctl.sh fleet sync repo/ifritah-api:v0.0.1 --type backend --tenant acme
```

## Local perf check

With a local Dokku container and at least 10 tenant pairs:

```sh
DASHBOARD_LOCAL_DOKKU_PERF=1 go test ./internal/web -run TestLocalDokkuSnapshotTenTenants -count=1 -v
```

The dashboard grid uses cached snapshots and a bounded parallel summary collector. Increase `DASHBOARD_SNAPSHOT_WORKERS` only if the host can handle more concurrent Docker inspect work.

Generate a password hash:

```sh
go run ./cmd/hashpw 'your-password'
# -> $2a$10$....
```

Set `DASHBOARD_ENV_FILE` to a writable mounted copy of `dashboard.env` to enable password changes from the UI. The production compose file mounts `./dashboard.env` at `/app/dashboard.env` and writes the new `ADMIN_PASSWORD_HASH` there.

Generate a session key (so sessions survive restarts):

```sh
openssl rand -hex 32
```

## Run locally (dev)

```sh
# dev-up.sh derives SCRIPTS_HOST_PATH from this checkout for the sidecar runner.
bash ./dev-up.sh
# UI:  http://localhost:8088
# Login: admin / admin   (override via ADMIN_USER / ADMIN_PASSWORD_HASH env)
```

To invoke Compose directly, provide the host checkout path explicitly:

```sh
SCRIPTS_HOST_PATH="$(cd .. && pwd)" docker compose -f docker-compose.dev.yml up --build
```

The dashboard talks to whatever container is named `dokku` on the **same Docker
daemon as the host's socket**. If you don't have a Dokku container locally, the
UI still loads but the apps grid will be empty and the Dokku pill will say
`down` — that proves the container, network, auth, and live updates work.

## Deploy on a server

```sh
cd /opt/deployment/dashboard
cp docker-compose.prod.yml /opt/dashboard/
cat > /opt/dashboard/dashboard.env <<EOF
ADMIN_USER=admin
ADMIN_PASSWORD_HASH=$(go run ./cmd/hashpw 'pick-something-strong')
SESSION_KEY=$(openssl rand -hex 32)
BASE_DOMAIN=ifritah.com
TENANT_NAME_PREFIX=prod-
EOF
cd /opt/dashboard
docker compose -f docker-compose.prod.yml up -d --build
```

Then expose it via Dokku just like any other app, e.g. as `admin-prod`:

```sh
dokku apps:create admin-prod
dokku ports:set admin-prod http:80:8080
dokku domains:set admin-prod admin.prod.ifritah.com
dokku letsencrypt:enable admin-prod
```

(Or front it with the host's nginx — the container already binds to
`127.0.0.1:8080`.)

## Security notes

- `/var/run/docker.sock` is **root-equivalent** on the host. Treat the
  dashboard like sudo: strong password, short-lived sessions, TLS in front.
- `SESSION_KEY` controls cookie integrity — set it to a stable 32-byte hex
  value or every restart logs everyone out.
- Password changes rewrite `ADMIN_PASSWORD_HASH` in `DASHBOARD_ENV_FILE`; keep
  that file writable only by the dashboard container and server admins.
- The container does not need its own `dokku` user; commands execute inside
  the dokku container via `docker exec`.
