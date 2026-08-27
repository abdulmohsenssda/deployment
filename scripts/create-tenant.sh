#!/usr/bin/env bash
# =============================================================================
# create-tenant.sh — Provision a new tenant on Dokku
# =============================================================================
# Creates a complete tenant with:
#   - Backend app (API) at <tenant>.<domain>/api
#   - Frontend app at <tenant>.<domain>
#   - Persistent storage for uploads/data
#   - Health checks and auto-restart
#
# TLS is NOT handled here. The host nginx in front of Dokku is owned by the
# operator and is expected to terminate TLS and forward plain HTTP to
# 127.0.0.1:DOKKU_PORT with the original Host header preserved.
#
# Usage:
#   ./scripts/create-tenant.sh <tenant-name> [options]
#
# Options:
#   --backend-image <image>   Docker image for backend (or deploy via git later)
#   --frontend-image <image>  Docker image for frontend (or deploy via git later)
#   --backend-port <port>     Port the backend listens on (default: 3000)
#   --frontend-port <port>    Port the frontend listens on (default: 80)
#   --no-database             Skip database creation
#   --env KEY=VALUE           Set env var (repeatable)
#   --git-only                Create apps without deploying (deploy via git push)
#   --dry-run                 Show plan without executing
#   --migrate <cmd>           Run migration after initial deploy (e.g. "npm run migrate")
#   --config <path>           Path to config.env file (default: ../config.env)
#
# Examples:
#   ./scripts/create-tenant.sh acme --git-only
#   ./scripts/create-tenant.sh acme --backend-image myregistry/ifritah-api:v1
#   ./scripts/create-tenant.sh acme --backend-image myregistry/ifritah-api:v1 --env SECRET_KEY=abc123
#   ./scripts/create-tenant.sh acme --config /opt/deployment/config.dev.env
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; }
info()  { echo -e "${BLUE}[i]${NC} $*"; }

# ---- Load config ----
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_DIR/config.env}"
for i in $(seq 1 $#); do
    if [ "${!i}" = "--config" ]; then
        j=$((i+1))
        if [ "$j" -gt "$#" ]; then
            error "--config requires a path"
            exit 1
        fi
        CONFIG_FILE="${!j}"
        break
    fi
done
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    error "Config file not found: $CONFIG_FILE"
    error "Run setup.sh first, or specify --config <path>."
    exit 1
fi

# ---- Parse arguments ----
TENANT_NAME=""
BACKEND_IMAGE=""
FRONTEND_IMAGE=""
# ifritah-go listens on 8090; templates expose 8000 for the frontend.
BACKEND_PORT="8090"
FRONTEND_PORT="8000"
NO_DATABASE=false
GIT_ONLY=false
DRY_RUN=false
FORCE_UPDATE=false
MIGRATE_CMD=""
declare -a ENV_VARS=()

has_env_var() {
    local key="$1"
    local ev
    for ev in "${ENV_VARS[@]+${ENV_VARS[@]}}"; do
        if [[ "$ev" == "$key="* ]]; then
            return 0
        fi
    done
    return 1
}

env_value() {
    local key="$1"
    local ev
    for ev in "${ENV_VARS[@]+${ENV_VARS[@]}}"; do
        if [[ "$ev" == "$key="* ]]; then
            printf '%s' "${ev#*=}"
            return 0
        fi
    done
    return 0
}

validate_docker_network_name() {
    local network="$1"
    case "$network" in
        *[!A-Za-z0-9_.-]*)
            error "Invalid Docker network name: $network"
            exit 1
            ;;
    esac
}

ensure_tenant_image_available() {
    local image="$1"
    local policy="${TENANT_IMAGE_PULL_POLICY:-${IMAGE_PULL_POLICY:-always}}"
    case "$policy" in
        always)
            log "Pulling image: $image"
            docker pull "$image" >/dev/null
            ;;
        missing)
            if docker image inspect "$image" >/dev/null 2>&1; then
                return 0
            fi
            log "Pulling image: $image"
            docker pull "$image" >/dev/null
            ;;
        never)
            if ! docker image inspect "$image" >/dev/null 2>&1; then
                error "Image is not present locally and TENANT_IMAGE_PULL_POLICY=never: $image"
                exit 1
            fi
            ;;
        *)
            error "TENANT_IMAGE_PULL_POLICY must be 'always', 'missing', or 'never' (got: $policy)"
            exit 1
            ;;
    esac
}

image_tag() {
    local image="$1"
    local tail="${image##*/}"
    if [[ "$tail" == *:* ]]; then
        printf '%s' "${tail##*:}"
    fi
}

find_existing_tenant_network() {
    dokku_shell "docker network ls --format '{{.Name}}' | awk '\$1 == \"web\" || /^tenant-/ { print; exit }'"
}

ensure_tenant_network() {
    local network="$1"
    local create_error=""
    local fallback_network=""
    validate_docker_network_name "$network"
    TENANT_NETWORK="$network"

    if dokku_shell "docker network inspect $network >/dev/null 2>&1"; then
        info "Network $network already exists"
        return 0
    fi

    log "Creating shared tenant docker network: $network"
    if ! dokku network:create "$network"; then
        warn "dokku network:create did not create $network; verifying Docker network state."
    fi

    if dokku_shell "docker network inspect $network >/dev/null 2>&1"; then
        info "Network $network is ready"
        return 0
    fi

    warn "Creating Docker network directly: $network"
    if dokku_shell "docker network create $network >/dev/null"; then
        if ! dokku_shell "docker network inspect $network >/dev/null 2>&1"; then
            error "Docker network was not created: $network"
            exit 1
        fi
        info "Network $network is ready"
        return 0
    fi

    create_error="$(dokku_shell "docker network create $network" 2>&1 || true)"
    if [ -n "$create_error" ]; then
        warn "docker network create failed for $network: $create_error"
    fi

    fallback_network="$(find_existing_tenant_network 2>/dev/null || true)"
    if [ -n "$fallback_network" ]; then
        validate_docker_network_name "$fallback_network"
        if dokku_shell "docker network inspect $fallback_network >/dev/null 2>&1"; then
            warn "Docker cannot allocate a new network; reusing existing tenant network: $fallback_network"
            TENANT_NETWORK="$fallback_network"
            return 0
        fi
    fi

    error "Failed to create Docker network: $network"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backend-image)  BACKEND_IMAGE="$2"; shift 2 ;;
        --frontend-image) FRONTEND_IMAGE="$2"; shift 2 ;;
        --backend-port)   BACKEND_PORT="$2"; shift 2 ;;
        --frontend-port)  FRONTEND_PORT="$2"; shift 2 ;;
        --no-database)    NO_DATABASE=true; shift ;;
        --env)            ENV_VARS+=("$2"); shift 2 ;;
        --git-only)       GIT_ONLY=true; shift ;;
        --dry-run)        DRY_RUN=true; shift ;;
        --update)         FORCE_UPDATE=true; shift ;;
        --migrate)        MIGRATE_CMD="$2"; shift 2 ;;
        --config)         CONFIG_FILE="$2"; shift 2 ;;
        -*)               error "Unknown option: $1"; exit 1 ;;
        *)
            if [ -z "$TENANT_NAME" ]; then
                TENANT_NAME="$1"
            else
                error "Unexpected argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# ---- Validate ----
if [ -z "$TENANT_NAME" ]; then
    echo "Usage: $0 <tenant-name> [options]"
    echo ""
    echo "Run with --help or see script header for all options."
    exit 1
fi

TENANT_NAME="$(tenant_full_name "$TENANT_NAME")" || exit 1

if [ -z "$TENANT_NAME" ] || [ ${#TENANT_NAME} -gt 63 ]; then
    error "Invalid tenant name (must be 1-63 chars, lowercase alphanumeric + hyphens)."
    exit 1
fi

# ---- Logging: tee everything to a per-run log file -------------------------
# So we (and the dashboard) can read what happened after the fact.
LOG_DIR="${LOG_DIR:-${PROJECT_DIR}/logs}"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="${LOG_DIR}/create-tenant-${TENANT_NAME}-$(date +%Y%m%d-%H%M%S).log"
if [ -w "$LOG_DIR" ]; then
    exec > >(tee -a "$LOG_FILE") 2>&1
    info "Logging to: $LOG_FILE"
fi

BASE_DOMAIN="${BASE_DOMAIN:?BASE_DOMAIN not set in config.env}"
STORAGE_ROOT="${STORAGE_ROOT:-/opt/tenant-data}"

MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"
HAS_DATABASE_URL=false
HAS_DB_PARTS=false
if has_env_var "DATABASE_URL"; then
    HAS_DATABASE_URL=true
fi
if has_env_var "DB_HOST" && has_env_var "DB_PORT" && has_env_var "DB_NAME" && has_env_var "DB_USER" && has_env_var "DB_PASSWORD"; then
    HAS_DB_PARTS=true
fi

BACKEND_APP="${TENANT_NAME}-backend"
FRONTEND_APP="${TENANT_NAME}-frontend"
TENANT_DOMAIN="${TENANT_NAME}.${BASE_DOMAIN}"
TENANT_NETWORK="${TENANT_APP_NETWORK:-web}"
public_protocol >/dev/null || exit 1
PUBLIC_TENANT_URL="$(public_tenant_url "$TENANT_NAME")" || exit 1
# Export so init-tenant-db.sh (invoked as child bash) inherits these — it uses
# them to reach the backend container directly over the tenant network for
# seed user registration (bypasses the frontend proxy CSRF).
export TENANT_NETWORK
export BACKEND_PORT

if [ -n "$BACKEND_IMAGE" ] && ! $HAS_DATABASE_URL && ! $HAS_DB_PARTS; then
    if $NO_DATABASE; then
        error "Backend image deploy requires database settings, but --no-database was set and no DATABASE_URL/DB_* env vars were provided."
        error "Either remove --no-database and configure MySQL, or provide explicit DB env vars."
        exit 1
    fi
    if [ -z "$MYSQL_ROOT_PASSWORD" ] || [ "$MYSQL_ROOT_PASSWORD" = "changeme" ]; then
        error "Backend image deploy requires database provisioning, but MYSQL_ROOT_PASSWORD is not configured in config.env."
        error "Set MYSQL_ROOT_PASSWORD, run scripts/verify-mysql.sh, then retry; or provide DATABASE_URL/DB_* via --env; or use --git-only."
        exit 1
    fi
fi

# Check if apps already exist
if dokku apps:exists "$BACKEND_APP" 2>/dev/null; then
    if [ "$FORCE_UPDATE" = "true" ]; then
        warn "App '$BACKEND_APP' already exists — continuing with --update (will re-deploy and re-seed)."
    else
        error "App '$BACKEND_APP' already exists. Tenant may already be provisioned."
        error "→ To update an existing tenant's image or env vars, use: update-tenant.sh $TENANT_NAME"
        error "→ To re-run provisioning anyway (e.g. after a partial failure), add --update to this command."
        exit 1
    fi
fi
if dokku apps:exists "$FRONTEND_APP" 2>/dev/null; then
    if [ "$FORCE_UPDATE" = "true" ]; then
        warn "App '$FRONTEND_APP' already exists — continuing with --update."
    else
        error "App '$FRONTEND_APP' already exists. Tenant may already be provisioned."
        error "→ To update an existing tenant's image or env vars, use: update-tenant.sh $TENANT_NAME"
        error "→ To re-run provisioning anyway (e.g. after a partial failure), add --update to this command."
        exit 1
    fi
fi

# fix_nginx_upstream rewrites Dokku's auto-generated nginx upstream block to use
# the Docker service hostname instead of a bridge IP address. The bridge IP changes
# on every container restart, causing 504 Gateway Timeout. Using the service hostname
# with Docker's internal DNS resolver (127.0.0.11) makes the mapping stable.
#
# Must be called AFTER dokku_git_from_image so it runs after Dokku's post-deploy
# nginx regeneration.
fix_nginx_upstream() {
    local app="$1"   # e.g. ssda123-frontend
    local svc="$2"   # e.g. ssda123-frontend.web
    local port="$3"  # e.g. 8000

    local conf="/home/dokku/${app}/nginx.conf"

    # Use sed inside the Dokku container to replace all bridge IPs in upstream block
    dokku_shell "
if [ -f '${conf}' ]; then
  # Replace the entire upstream server block with the Docker hostname
  python3 -c \"
import re
with open('${conf}') as f: c = f.read()
p = r'upstream ${app}-${port} \{[^}]*\}'
r = 'upstream ${app}-${port} {\n  server ${svc}:${port};\n}'
c2 = re.sub(p, r, c, flags=re.DOTALL)
if c2 != c:
  with open('${conf}','w') as f: f.write(c2)
  print('[i] nginx upstream fixed for ${app} -> ${svc}:${port}')
\"
  nginx -s reload 2>/dev/null || true
fi
" 2>&1 || warn "Could not fix nginx upstream for ${app} — tenant may not be accessible until next deploy"
}

create_dokku_app() {
    local app="$1"
    log "Creating app: $app"
    if dokku apps:create "$app"; then
        return 0
    fi
    if dokku apps:exists "$app" 2>/dev/null; then
        warn "dokku apps:create returned non-zero after creating $app; continuing."
        return 0
    fi
    error "Failed to create app: $app"
    exit 1
}

# ---- Show plan ----
echo ""
info "=== Tenant Provisioning Plan ==="
info "  Tenant:         $TENANT_NAME"
if [ -n "${TENANT_NAME_PREFIX:-}" ]; then
    info "  Tenant prefix:  $(tenant_name_prefix)"
fi
info "  Domain:         $TENANT_DOMAIN"
info "  Backend app:    $BACKEND_APP  → internal only (${BACKEND_APP}.web:${BACKEND_PORT})"
info "  Frontend app:   $FRONTEND_APP → $TENANT_DOMAIN"
info "  Docker network: $TENANT_NETWORK"
info "  Backend port:   $BACKEND_PORT"
info "  Frontend port:  $FRONTEND_PORT"
info "  Storage:        $STORAGE_ROOT/$TENANT_NAME/{uploads,data}"
if ! $NO_DATABASE; then
    info "  Database:       MySQL → tenant_${TENANT_NAME} on ${MYSQL_HOST:-127.0.0.1}"
else
    info "  Database:       skipped (--no-database)"
fi
if [ -n "$BACKEND_IMAGE" ]; then
    info "  Backend image:  $BACKEND_IMAGE"
fi
if [ -n "$FRONTEND_IMAGE" ]; then
    info "  Frontend image: $FRONTEND_IMAGE"
fi
if $GIT_ONLY; then
    info "  Deploy method:  git push (no image deploy now)"
fi
for ev in "${ENV_VARS[@]+"${ENV_VARS[@]}"}"; do
    info "  Env var:        $ev"
done
echo ""

if $DRY_RUN; then
    warn "Dry run — no changes made."
    exit 0
fi

# =============================================================================
# PROVISION
# =============================================================================

# ---- 1. Create Dokku apps ----
create_dokku_app "$BACKEND_APP"
create_dokku_app "$FRONTEND_APP"

# ---- 2. Set domains ----
log "Configuring domains..."
# The frontend owns the public tenant domain. The backend is reached only from
# the frontend over the per-tenant Docker network; giving both apps the same
# public domain makes Dokku generate duplicate nginx server_name blocks.
dokku domains:clear "$BACKEND_APP"

dokku domains:clear "$FRONTEND_APP"
dokku domains:add "$FRONTEND_APP" "$TENANT_DOMAIN"

# ---- 3. Inter-app networking ----
# /api routing happens INSIDE the frontend Go app (it reads BACKEND_URL and
# proxies HTTP itself). We do NOT write a Dokku nginx /api snippet here —
# referencing a sibling app from a custom nginx.conf.d snippet breaks
# `nginx:validate-config` (the upstream alias doesn't resolve from the
# dokku-nginx context), which silently blocks reloads for ALL tenants.
#
# Instead: attach both apps to a shared tenant docker network so the frontend
# container can reach the backend by Dokku's auto-alias "<app>.web".

DOKKU_PORT="${DOKKU_PORT:-8080}"
NGINX_CLIENT_MAX_BODY_SIZE="${NGINX_CLIENT_MAX_BODY_SIZE:-50m}"

ensure_tenant_network "$TENANT_NETWORK"

log "Attaching apps to $TENANT_NETWORK"
# Dokku 0.30+ rejects setting attach-post-create AND attach-post-deploy for the
# same network on the same app ("Network name already associated with this app").
# attach-post-create alone is enough: it attaches on container create which
# covers both image deploys (ps:rebuild) and git-push deploys.
dokku network:set "$BACKEND_APP"  attach-post-create "$TENANT_NETWORK"
dokku network:set "$FRONTEND_APP" attach-post-create "$TENANT_NETWORK"

# Attach the dokku container itself to the tenant network so its internal
# nginx can resolve <app>.web hostnames via Docker DNS (used by fix_nginx_upstream).
# Without this, dokku's nginx runs only on 'bridge' and returns 502 when the
# upstream block references a service hostname from a user-defined network.
# `docker network connect` errors if already connected — swallow that.
DOKKU_CONTAINER="${DOKKU_CONTAINER:-dokku}"
if docker network inspect "$TENANT_NETWORK" --format '{{range $k,$v := .Containers}}{{$v.Name}}{{"\n"}}{{end}}' 2>/dev/null | grep -qx "$DOKKU_CONTAINER"; then
    info "${DOKKU_CONTAINER} already attached to ${TENANT_NETWORK}"
else
    if docker network connect "$TENANT_NETWORK" "$DOKKU_CONTAINER" 2>&1; then
        info "Attached ${DOKKU_CONTAINER} to ${TENANT_NETWORK}"
    else
        warn "Could not attach ${DOKKU_CONTAINER} to ${TENANT_NETWORK} — inter-app proxy may fail with 502"
    fi
fi

# ---- 4. Set ports ----
# Dokku edge nginx listens on :80 inside its own network; host nginx (if any)
# just forwards to DOKKU_PORT.
LISTEN_PORT=80
log "Setting container ports (Dokku edge listens on :${LISTEN_PORT})..."
dokku ports:set "$BACKEND_APP"  "http:${LISTEN_PORT}:${BACKEND_PORT}"
dokku ports:set "$FRONTEND_APP" "http:${LISTEN_PORT}:${FRONTEND_PORT}"

log "Disabling public proxy for backend app (internal-only)..."
dokku proxy:disable "$BACKEND_APP" 2>/dev/null || true

# ---- 5. Persistent storage ----
log "Creating persistent storage..."
mkdir -p "$STORAGE_ROOT/$TENANT_NAME/uploads"
mkdir -p "$STORAGE_ROOT/$TENANT_NAME/data"
chown -R 32767:32767 "$STORAGE_ROOT/$TENANT_NAME" 2>/dev/null || true

# Idempotent mount: skip if the mount pair is already registered. Prevents
# --update / retry-after-partial-failure from aborting on "Mount path already exists".
ensure_storage_mount() {
    local app="$1" spec="$2"
    if dokku storage:list "$app" 2>/dev/null | grep -qF "$spec"; then
        info "Storage mount already exists: $spec"
    else
        dokku storage:mount "$app" "$spec"
    fi
}
ensure_storage_mount "$BACKEND_APP" "$STORAGE_ROOT/$TENANT_NAME/uploads:/app/uploads"
ensure_storage_mount "$BACKEND_APP" "$STORAGE_ROOT/$TENANT_NAME/data:/app/data"

# ---- 6. Environment variables ----
log "Setting environment variables..."
dokku config:set --no-restart "$BACKEND_APP" \
    TENANT_ID="$TENANT_NAME" \
    PORT="$BACKEND_PORT" \
    SERVER_PORT="$BACKEND_PORT" \
    NATS_URL="${NATS_URL:-nats://host.docker.internal:4222}" \
    BASEURL="${BASEURL:-/api/v2}" \
    JWT_SECERT_KEY="${JWT_SECERT_KEY:-$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 48)}"

# Frontend speaks to backend over the per-tenant docker network. Dokku exposes
# each web container under the alias "<app>.web" inside attached networks.
dokku config:set --no-restart "$FRONTEND_APP" \
    TENANT_ID="$TENANT_NAME" \
    PORT="$FRONTEND_PORT" \
    APP_DOMAIN="$TENANT_DOMAIN" \
    BACKEND_URL="http://${BACKEND_APP}.web:${BACKEND_PORT}" \
    API_URL="${PUBLIC_TENANT_URL}/api"

# Message service (if configured)
MSG_HOST="${MSG_HOST:-}"
MSG_PORT="${MSG_PORT:-}"
if [ -n "$MSG_HOST" ]; then
    log "Configuring message service: $MSG_HOST:${MSG_PORT:-default}"
    dokku config:set --no-restart "$BACKEND_APP" \
        MSG_HOST="$MSG_HOST" \
        ${MSG_PORT:+MSG_PORT="$MSG_PORT"}
fi

# Docker host access — ensure containers can reach host services
dokku docker-options:add "$BACKEND_APP" deploy,run "--add-host=host.docker.internal:host-gateway" 2>/dev/null || true

# User-provided env vars
for ev in "${ENV_VARS[@]+"${ENV_VARS[@]}"}"; do
    if [[ "$ev" == *"="* ]]; then
        dokku config:set --no-restart "$BACKEND_APP" "$ev"
    fi
done

# ---- 7. External MySQL database ----
MYSQL_MASTER_DB="${MYSQL_MASTER_DB:-zatca_master}"
# Host pattern for the tenant DB user. '%' works for all setups:
# - MySQL as a host service: containers connect from their Docker IP
# - MySQL in Docker: same
# The old default '172.%' broke when MySQL runs on the host and the GRANT
# was created via a unix socket (localhost), or when Docker uses a non-172 subnet.
MYSQL_TENANT_HOST="${MYSQL_TENANT_HOST:-%}"
MYSQL_APP_HOST="$(mysql_host_for_container "${MYSQL_HOST:-host.docker.internal}")"

TENANT_DB_NAME="tenant_${TENANT_NAME//-/_}"
TENANT_DB_USER="usr_${TENANT_NAME//-/_}"
DB_PROVISIONED=false

if ! $NO_DATABASE; then
    if [ -z "$MYSQL_ROOT_PASSWORD" ] || [ "$MYSQL_ROOT_PASSWORD" = "changeme" ]; then
        warn "MYSQL_ROOT_PASSWORD not set in config.env — skipping database creation."
    else
        # Generate a random password — but if the tenant backend already has a
        # DB_PASSWORD in Dokku config (re-run scenario), reuse it so the running
        # container does not get a mismatched credential.
        TENANT_DB_PASS=""
        if dokku apps:exists "$BACKEND_APP" 2>/dev/null; then
            TENANT_DB_PASS="$(dokku config:get "$BACKEND_APP" DB_PASSWORD 2>/dev/null || true)"
        fi
        if [ -z "$TENANT_DB_PASS" ]; then
            TENANT_DB_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)
        fi

        log "Creating MySQL database: $TENANT_DB_NAME (user: $TENANT_DB_USER@'$MYSQL_TENANT_HOST')"

        # dev-only diag
        if [ "${DASHBOARD_ENV:-}" = "dev" ]; then
            info "[dev-diag] MYSQL_CLIENT_MODE=${MYSQL_CLIENT_MODE:-<unset>} _MYSQL_VIA=${_MYSQL_VIA:-<unset>}"
            info "[dev-diag] MYSQL_HOST=${MYSQL_HOST:-<unset>} MYSQL_PORT=${MYSQL_PORT:-<unset>} MYSQL_ROOT_USER=${MYSQL_ROOT_USER:-<unset>}"
            info "[dev-diag] MYSQL_TENANT_HOST='${MYSQL_TENANT_HOST}' MYSQL_APP_HOST=${MYSQL_APP_HOST}"
            info "[dev-diag] TENANT_DB_USER=${TENANT_DB_USER} TENANT_DB_NAME=${TENANT_DB_NAME}"
            info "[dev-diag] SQL: DROP @'localhost'; CREATE/ALTER @'${MYSQL_TENANT_HOST}'; GRANT ON ${TENANT_DB_NAME}.*"
            set +e
        fi
        run_mysql <<SQLEOF
CREATE DATABASE IF NOT EXISTS \`${TENANT_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS '${TENANT_DB_USER}'@'localhost';
CREATE USER IF NOT EXISTS '${TENANT_DB_USER}'@'${MYSQL_TENANT_HOST}' IDENTIFIED BY '${TENANT_DB_PASS}';
ALTER USER '${TENANT_DB_USER}'@'${MYSQL_TENANT_HOST}' IDENTIFIED BY '${TENANT_DB_PASS}';
GRANT ALL PRIVILEGES ON \`${TENANT_DB_NAME}\`.* TO '${TENANT_DB_USER}'@'${MYSQL_TENANT_HOST}';
SQLEOF
        _mysql_rc=$?
        if [ "${DASHBOARD_ENV:-}" = "dev" ]; then
            info "[dev-diag] run_mysql exit=${_mysql_rc}; mysql.user rows for ${TENANT_DB_USER}:"
            run_mysql -N -B -e "SELECT CONCAT(user,'@',host) FROM mysql.user WHERE user='${TENANT_DB_USER}';" 2>&1 | sed 's/^/[dev-diag]   /' || true
            set -e
        fi
        if [ "${_mysql_rc}" -ne 0 ]; then
            error "MySQL tenant provisioning failed (exit ${_mysql_rc})"
            exit "${_mysql_rc}"
        fi

        # Register in master database
        log "Registering tenant in master database..."
        run_mysql "$MYSQL_MASTER_DB" <<SQLEOF
INSERT INTO tenant (name, db_name)
VALUES ('${TENANT_NAME}', '${TENANT_DB_NAME}')
ON DUPLICATE KEY UPDATE enabled=1;
SQLEOF

        # Inject DB env vars into the backend container.
        # Both naming conventions: modern (DB_HOST/DB_USER/...) and legacy
        # ifritah-go (HOST/DBUSER/PASSWORD/DBNAME — HOST is host:port).
        DATABASE_URL="mysql://${TENANT_DB_USER}:${TENANT_DB_PASS}@${MYSQL_APP_HOST}:${MYSQL_PORT}/${TENANT_DB_NAME}"
        dokku config:set --no-restart "$BACKEND_APP" \
            DATABASE_URL="$DATABASE_URL" \
            DB_HOST="$MYSQL_APP_HOST" \
            DB_PORT="$MYSQL_PORT" \
            DB_NAME="$TENANT_DB_NAME" \
            DB_USER="$TENANT_DB_USER" \
            DB_PASSWORD="$TENANT_DB_PASS" \
            HOST="${MYSQL_APP_HOST}:${MYSQL_PORT}" \
            DBUSER="$TENANT_DB_USER" \
            PASSWORD="$TENANT_DB_PASS" \
            DBNAME="$TENANT_DB_NAME"

        log "Database ready: $TENANT_DB_NAME"

        if [ -n "$BACKEND_IMAGE" ]; then
            log "Initializing tenant database schema from backend image..."
            bash "$SCRIPT_DIR/init-tenant-db.sh" "$TENANT_NAME" \
                --schema-only \
                --backend-image "$BACKEND_IMAGE" \
                --config "$CONFIG_FILE" \
                --env "DB_HOST=$MYSQL_APP_HOST" \
                --env "DB_PORT=$MYSQL_PORT" \
                --env "DB_USER=$TENANT_DB_USER" \
                --env "DB_PASSWORD=$TENANT_DB_PASS"
            DB_PROVISIONED=true
        else
            warn "No backend image supplied; skipping schema initialization."
            warn "Run later: bash scripts/init-tenant-db.sh $TENANT_NAME --backend-image <image> --schema-only"
        fi
    fi
fi

# ---- 8. Health checks ----
# Modern Dokku (>= 0.30) uses an app-root CHECKS file or app.json for HTTP
# path checks; the legacy `checks:set <app> web http-path=...` form was
# removed (only `wait-to-retire` is now valid for checks:set). We write a
# CHECKS file into each app's working dir on the dokku host so health checks
# are configured before first deploy.
log "Configuring health checks..."
dokku_shell "mkdir -p /home/dokku/${BACKEND_APP} && echo '/api/health' > /home/dokku/${BACKEND_APP}/CHECKS" || warn "could not seed backend CHECKS"
dokku_shell "mkdir -p /home/dokku/${FRONTEND_APP} && echo '/' > /home/dokku/${FRONTEND_APP}/CHECKS" || warn "could not seed frontend CHECKS"

# ---- 9. Deploy (if images provided) ----
if ! $GIT_ONLY; then
    if [ -n "$BACKEND_IMAGE" ]; then
        log "Deploying backend from image: $BACKEND_IMAGE"
        ensure_tenant_image_available "$BACKEND_IMAGE"
        dokku config:set --no-restart "$BACKEND_APP" \
            APP_IMAGE_VERSION="$(image_tag "$BACKEND_IMAGE")" \
            APP_IMAGE_REF="$BACKEND_IMAGE"
        dokku_git_from_image "$BACKEND_APP" "$BACKEND_IMAGE"
    else
        info "No backend image — deploy later with: git push dokku@${BASE_DOMAIN}:${BACKEND_APP} main"
    fi

    if [ -n "$FRONTEND_IMAGE" ]; then
        log "Deploying frontend from image: $FRONTEND_IMAGE"
        ensure_tenant_image_available "$FRONTEND_IMAGE"
        dokku config:set --no-restart "$FRONTEND_APP" \
            APP_IMAGE_VERSION="$(image_tag "$FRONTEND_IMAGE")" \
            APP_IMAGE_REF="$FRONTEND_IMAGE" \
            COOKIE_SECURE=false
        dokku_git_from_image "$FRONTEND_APP" "$FRONTEND_IMAGE"

        # Dokku's nginx config uses the bridge network IP which changes on every container
        # restart. Fix it immediately to use the Docker service hostname on the web network,
        # which is stable and resolved via Docker's internal DNS (127.0.0.11).
        fix_nginx_upstream "$FRONTEND_APP" "${FRONTEND_APP}.web" "8000"
    else
        info "No frontend image — deploy later with: git push dokku@${BASE_DOMAIN}:${FRONTEND_APP} main"
    fi
fi

# ---- 10. Seed tenant users ----
if $DB_PROVISIONED && ! $GIT_ONLY; then
    ADMIN_USER="$(env_value ADMIN_USER)"
    ADMIN_PASSWORD="$(env_value ADMIN_PASSWORD)"
    MANAGER_USER="$(env_value MANAGER_USER)"
    MANAGER_PASSWORD="$(env_value MANAGER_PASSWORD)"
    COMPANY_NAME="$(env_value COMPANY_NAME)"

    if [ -n "$ADMIN_USER$ADMIN_PASSWORD$MANAGER_USER$MANAGER_PASSWORD" ]; then
        if [ -n "$BACKEND_IMAGE" ] && [ -n "$FRONTEND_IMAGE" ]; then
            log "Seeding tenant users..."
            seed_args=("$TENANT_NAME" --seed-only --config "$CONFIG_FILE" \
                --env "DB_HOST=$MYSQL_APP_HOST" \
                --env "DB_PORT=$MYSQL_PORT" \
                --env "DB_USER=$TENANT_DB_USER" \
                --env "DB_PASSWORD=$TENANT_DB_PASS")
            [ -n "$ADMIN_USER" ] && seed_args+=(--env "ADMIN_USER=$ADMIN_USER")
            [ -n "$ADMIN_PASSWORD" ] && seed_args+=(--env "ADMIN_PASSWORD=$ADMIN_PASSWORD")
            [ -n "$MANAGER_USER" ] && seed_args+=(--env "MANAGER_USER=$MANAGER_USER")
            [ -n "$MANAGER_PASSWORD" ] && seed_args+=(--env "MANAGER_PASSWORD=$MANAGER_PASSWORD")
            [ -n "$COMPANY_NAME" ] && seed_args+=(--env "COMPANY_NAME=$COMPANY_NAME")
            bash "$SCRIPT_DIR/init-tenant-db.sh" "${seed_args[@]}"
        else
            warn "Seed credentials supplied, but both backend and frontend images must be deployed before API registration."
            warn "Run later: bash scripts/init-tenant-db.sh $TENANT_NAME --seed-only --env ADMIN_USER=... --env ADMIN_PASSWORD=..."
        fi
    else
        warn "No seed user credentials supplied; skipping admin/manager user creation."
    fi
fi

# ---- 11. External nginx ----
info "Host nginx (operator-managed) wildcards *.${BASE_DOMAIN} → 127.0.0.1:${DOKKU_PORT}; nothing to do per-tenant."
info "Verify once on the host that the wildcard vhost forwards with 'Host \$host' preserved, then: sudo nginx -t && sudo systemctl reload nginx"

# ---- 12. Run database migration ----
if [ -n "$MIGRATE_CMD" ] && [ -n "$BACKEND_IMAGE" ]; then
    log "Running database migration: $MIGRATE_CMD"
    if dokku run "$BACKEND_APP" $MIGRATE_CMD; then
        log "Migration completed successfully."
    else
        warn "Migration failed. You may need to run it manually:"
        warn "  dokku run $BACKEND_APP $MIGRATE_CMD"
    fi
elif [ -n "$MIGRATE_CMD" ] && [ -z "$BACKEND_IMAGE" ]; then
    warn "--migrate specified but no backend image deployed yet. Skipping migration."
    warn "Run manually after deploy: dokku run $BACKEND_APP $MIGRATE_CMD"
fi

# ---- DNS wildcard check ----
# Fail loudly if *.BASE_DOMAIN doesn't resolve — the tenant URL below will
# 404 in a browser otherwise, with no obvious hint that DNS is the problem.
dns_ok=true
if command -v getent >/dev/null 2>&1; then
    if ! getent hosts "$TENANT_DOMAIN" >/dev/null 2>&1; then
        dns_ok=false
    fi
elif command -v dig >/dev/null 2>&1; then
    if [ -z "$(dig +short "$TENANT_DOMAIN" A 2>/dev/null)" ]; then
        dns_ok=false
    fi
elif command -v nslookup >/dev/null 2>&1; then
    if ! nslookup "$TENANT_DOMAIN" >/dev/null 2>&1; then
        dns_ok=false
    fi
fi

# ---- Done ----
echo ""
log "============================================"
log "  Tenant '$TENANT_NAME' created!"
log ""
log "  Frontend: ${PUBLIC_TENANT_URL}"
log "  API:      ${PUBLIC_TENANT_URL}/api"
log "  Storage:  ${STORAGE_ROOT}/${TENANT_NAME}/"
log ""
if ! $dns_ok; then
    warn ""
    warn "  DNS: ${TENANT_DOMAIN} does NOT resolve yet."
    warn "  Add a WILDCARD A record on your DNS provider (one time, not per tenant):"
    warn "      Host:   *.${BASE_DOMAIN%.*.*}   (short label, e.g. *.odoo)"
    warn "      Type:   A"
    warn "      Answer: <this server's public IP>"
    warn "  Every future tenant will resolve automatically once the wildcard is live."
    warn ""
fi
log "  Routing: host nginx (operator-managed TLS) → 127.0.0.1:${DOKKU_PORT} → Dokku → ${TENANT_DOMAIN}"
log "  No per-tenant host port; Dokku routes by Host header."
log ""
log "  Dashboard: http://localhost:8088 (Apps page)"
log "  View logs:  dokku logs ${BACKEND_APP} --tail"
log "  Status:     dokku ps:report ${BACKEND_APP}"
log "============================================"
echo ""
