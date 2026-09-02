#!/usr/bin/env bash
# =============================================================================
# install.sh — One-shot non-interactive bootstrap
# =============================================================================
# Wraps setup.sh + setup-dev-tenant.sh so a fresh server is fully provisioned
# from a single command, no prompts. The underlying scripts are untouched.
#
# Usage:
#   sudo bash install.sh --base-domain dev.example.com \
#                        --acme-email admin@example.com \
#                        --mysql-admin-user dokku_admin \
#                        --mysql-admin-password 'strong-password' \
#                        --dockerhub-user abdulmohsenssda
#
# Flags (all map 1:1 to config.env keys):
#   --base-domain        BASE_DOMAIN          (required)
#   --acme-email         ACME_EMAIL           (default: admin@<domain>)
#   --nginx-mode         NGINX_MODE           (behind-nginx only; default: behind-nginx)
#   --dokku-port         DOKKU_PORT           (default: 8080)
#   --mysql-host         MYSQL_HOST           (default: host.docker.internal)
#   --mysql-port         MYSQL_PORT           (default: 3306)
#   --mysql-admin-user  MYSQL_ADMIN_USER     (default: dokku_admin)
#   --mysql-admin-password MYSQL_ADMIN_PASSWORD (required when writing config)
#   --mysql-user         legacy alias for --mysql-admin-user
#   --mysql-password     legacy alias for --mysql-admin-password
#   --master-db          MYSQL_MASTER_DB      (default: zatca_master)
#   --dockerhub-user     DOCKERHUB_USERNAME   (required for auto-pull)
#   --pull-tag           PULL_TAG             (default: dev)
#   --dev-tenant         DEV_TENANT           (default: dev)
#   --dev-tag            DEV_TAG              (default: dev)
#   --webhook-secret     WEBHOOK_SECRET       (default: auto-generated)
#   --storage-root       STORAGE_ROOT         (default: /opt/tenant-data)
#   --backup-dir         BACKUP_DIR           (default: /opt/tenant-backups)
#
# Behavior flags:
#   --dev-only           Provision the dev tenant only (default; included for clarity)
#   --skip-dev-tenant    Run setup.sh but don't create the dev tenant
#   --reuse-config       Skip writing config.env if it already exists
#   --config <path>      Custom config.env location
#
# All flags can also be supplied via environment variables of the same name
# (e.g. BASE_DOMAIN=dev.example.com), or by sourcing a pre-filled config.env
# next to this script before invocation.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/config.env}"
INSTALL_ENV="${INSTALL_ENV:-$SCRIPT_DIR/install.env}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()   { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; }
info()  { echo -e "${BLUE}[i]${NC} $*"; }

# Load install.env if present (preferred over CLI flags)
if [ -f "$INSTALL_ENV" ]; then
    info "Loading values from $INSTALL_ENV"
    set -a; source "$INSTALL_ENV"; set +a
fi

# Defaults (env-var overridable)
: "${BASE_DOMAIN:=}"
: "${ACME_EMAIL:=}"
: "${ENABLE_SSL:=false}"
: "${NGINX_MODE:=behind-nginx}"
: "${DOKKU_PORT:=8080}"
: "${MYSQL_HOST:=host.docker.internal}"
: "${MYSQL_PORT:=3306}"
if [ -z "${MYSQL_ADMIN_USER:-}" ]; then
    if [ -n "${MYSQL_ROOT_USER:-}" ]; then
        MYSQL_ADMIN_USER="$MYSQL_ROOT_USER"
    elif [ -n "${MYSQL_ROOT_PASSWORD:-}" ] && [ -z "${MYSQL_ADMIN_PASSWORD:-}" ]; then
        MYSQL_ADMIN_USER="root"
    else
        MYSQL_ADMIN_USER="dokku_admin"
    fi
fi
: "${MYSQL_ADMIN_PASSWORD:=${MYSQL_ROOT_PASSWORD:-}}"
: "${MYSQL_MASTER_DB:=zatca_master}"
: "${MYSQL_TENANT_HOST:=%}"
: "${DOCKERHUB_USERNAME:=}"
: "${PULL_TAG:=dev}"
: "${APPS:=backend frontend}"
: "${APP_IMAGE_backend:=ifritah-api}"
: "${APP_IMAGE_frontend:=ifritah-web}"
: "${DEV_TENANT:=dev}"
: "${DEV_TAG:=dev}"
: "${WEBHOOK_SECRET:=}"
: "${STORAGE_ROOT:=/opt/tenant-data}"
: "${BACKUP_DIR:=/opt/tenant-backups}"
: "${MIGRATE_CMD:=atlas migrate apply --dir file:///app/migrations --url \"\$DATABASE_URL\"}"

DEV_ONLY=true
SKIP_DEV_TENANT=false
REUSE_CONFIG=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-domain)      BASE_DOMAIN="$2"; shift 2 ;;
        --acme-email)       ACME_EMAIL="$2"; shift 2 ;;
        --nginx-mode)       NGINX_MODE="$2"; shift 2 ;;
        --dokku-port)       DOKKU_PORT="$2"; shift 2 ;;
        --mysql-host)       MYSQL_HOST="$2"; shift 2 ;;
        --mysql-port)       MYSQL_PORT="$2"; shift 2 ;;
        --mysql-admin-user|--mysql-user) MYSQL_ADMIN_USER="$2"; shift 2 ;;
        --mysql-admin-password|--mysql-password) MYSQL_ADMIN_PASSWORD="$2"; shift 2 ;;
        --master-db)        MYSQL_MASTER_DB="$2"; shift 2 ;;
        --dockerhub-user)   DOCKERHUB_USERNAME="$2"; shift 2 ;;
        --pull-tag)         PULL_TAG="$2"; shift 2 ;;
        --dev-tenant)       DEV_TENANT="$2"; shift 2 ;;
        --dev-tag)          DEV_TAG="$2"; shift 2 ;;
        --webhook-secret)   WEBHOOK_SECRET="$2"; shift 2 ;;
        --storage-root)     STORAGE_ROOT="$2"; shift 2 ;;
        --backup-dir)       BACKUP_DIR="$2"; shift 2 ;;
        --dev-only)         DEV_ONLY=true; shift ;;
        --skip-dev-tenant)  SKIP_DEV_TENANT=true; shift ;;
        --reuse-config)     REUSE_CONFIG=true; shift ;;
        --config)           CONFIG_FILE="$2"; shift 2 ;;
        -h|--help)          sed -n '1,45p' "$0"; exit 0 ;;
        *)                  error "Unknown flag: $1"; exit 1 ;;
    esac
done

# ---- Sanity checks ----
if [ "$(id -u)" -ne 0 ]; then
    error "Run as root: sudo bash $0 [...]"
    exit 1
fi
if ! command -v docker &>/dev/null; then
    error "Docker not installed. https://docs.docker.com/engine/install/"
    exit 1
fi

WRITE_CONFIG=true
if [ -f "$CONFIG_FILE" ] && $REUSE_CONFIG; then
    info "Reusing existing $CONFIG_FILE (--reuse-config)."
    WRITE_CONFIG=false
fi

if $WRITE_CONFIG; then
    # Required values
    [ -z "$BASE_DOMAIN" ]         && { error "--base-domain or BASE_DOMAIN is required"; exit 1; }
    [ -z "$MYSQL_ADMIN_PASSWORD" ] && { error "--mysql-admin-password or MYSQL_ADMIN_PASSWORD is required"; exit 1; }
    [ -z "$ACME_EMAIL" ] && ACME_EMAIL="admin@${BASE_DOMAIN}"
    [ -z "$WEBHOOK_SECRET" ] && WEBHOOK_SECRET="$(openssl rand -hex 32 2>/dev/null || head -c32 /dev/urandom | base64)"

    log "Writing $CONFIG_FILE"
    umask 077
    cat > "$CONFIG_FILE" <<EOF
# Auto-generated by install.sh on $(date -u +%FT%TZ)
BASE_DOMAIN=${BASE_DOMAIN}
ACME_EMAIL=${ACME_EMAIL}
ENABLE_SSL=${ENABLE_SSL}
NGINX_MODE=${NGINX_MODE}
DOKKU_PORT=${DOKKU_PORT}
NGINX_CONF_DIR=/etc/nginx/dokku-tenants
STORAGE_ROOT=${STORAGE_ROOT}
BACKUP_DIR=${BACKUP_DIR}

MYSQL_HOST=${MYSQL_HOST}
MYSQL_PORT=${MYSQL_PORT}
MYSQL_ADMIN_USER=${MYSQL_ADMIN_USER}
MYSQL_ADMIN_PASSWORD=${MYSQL_ADMIN_PASSWORD}
MYSQL_MASTER_DB=${MYSQL_MASTER_DB}
MYSQL_TENANT_HOST=${MYSQL_TENANT_HOST}

DOCKERHUB_USERNAME=${DOCKERHUB_USERNAME}
PULL_TAG=${PULL_TAG}

APPS="${APPS}"
APP_IMAGE_backend=${APP_IMAGE_backend}
APP_IMAGE_frontend=${APP_IMAGE_frontend}

DEV_TENANT=${DEV_TENANT}
DEV_TAG=${DEV_TAG}

# Single-quoted: \$DATABASE_URL must stay literal here. It's expanded inside
# the backend container by Dokku at run time, not when config.env is sourced.
MIGRATE_CMD='${MIGRATE_CMD}'

WEBHOOK_SECRET=${WEBHOOK_SECRET}
EOF
    chmod 600 "$CONFIG_FILE"
fi

# ---- Run the underlying scripts non-interactively ----
# setup.sh prompts:
#   1. "Use existing config?" → y     (because we just wrote one)
#   2. "Create your first tenant now?" → n  (we use setup-dev-tenant.sh instead)
# Anything else has a sensible default that the user pressing Enter would pick.
log "Running scripts/setup.sh non-interactively..."
{
    echo "y"   # use existing config
    echo "n"   # don't create first tenant here
    # extra blank lines to absorb any unexpected prompt with its default
    for _ in $(seq 1 30); do echo ""; done
} | bash "$SCRIPT_DIR/scripts/setup.sh" --config "$CONFIG_FILE"

if $SKIP_DEV_TENANT; then
    log "Skipping dev tenant (--skip-dev-tenant)."
else
    log "Creating dev tenant '${DEV_TENANT}' pinned to :${DEV_TAG}..."
    bash "$SCRIPT_DIR/scripts/setup-dev-tenant.sh" --config "$CONFIG_FILE"
fi

echo ""
log "Install complete."
DEV_SCHEME="http"
[ "${ENABLE_SSL:-false}" = "true" ] && DEV_SCHEME="https"
info "Dev URL:        ${DEV_SCHEME}://${DEV_TENANT}.${BASE_DOMAIN}"
info "Auto-deploy:    webhook can deploy the exact VERSION tag from your app repo"
info "Manual prod:    bash scripts/deploy-all.sh ${DOCKERHUB_USERNAME:-<user>}/ifritah-api:<release-tag> --tenant <client>"
info "Logs:           bash scripts/tail-logs.sh ${DEV_TENANT}-backend"
