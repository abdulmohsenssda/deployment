#!/usr/bin/env bash
# =============================================================================
# cleanup-broken-tenant.sh — Force-clean a broken or half-created Dokku tenant
# =============================================================================
# Usage:
#   ./scripts/cleanup-broken-tenant.sh <tenant-name> [--delete-data] [--force]
#   ./scripts/cleanup-broken-tenant.sh <tenant-name> --config /opt/deployment/config.dev.env
#
# This is stronger than remove-tenant.sh. It is meant for failed tenant creates
# where Dokku may have stale storage-registry attachments, half-created apps,
# DB rows/users, tenant network, or local dokku images left behind.
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
error() { echo -e "${RED}[x]${NC} $*" >&2; }
info()  { echo -e "${BLUE}[i]${NC} $*"; }

# Parse --config early (before sourcing)
CONFIG_FILE="$PROJECT_DIR/config.env"
for i in $(seq 1 $#); do
    if [ "${!i}" = "--config" ]; then
        j=$((i+1))
        CONFIG_FILE="${!j}"
        break
    fi
done

[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

TENANT_NAME=""
DELETE_DATA=false
FORCE=false
DRY_RUN=false
SKIP_STORAGE_REPAIR=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --delete-data) DELETE_DATA=true; shift ;;
        --force) FORCE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --skip-storage-repair) SKIP_STORAGE_REPAIR=true; shift ;;
        --config) shift 2 ;;
        -*) error "Unknown option: $1"; exit 1 ;;
        *) [ -z "$TENANT_NAME" ] && TENANT_NAME="$1"; shift ;;
    esac
done

if [ -z "$TENANT_NAME" ]; then
    error "Usage: $0 <tenant-name> [--delete-data] [--force]"
    exit 1
fi

TENANT_NAME="$(tenant_full_name "$TENANT_NAME")" || exit 1

if ! [[ "$TENANT_NAME" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; then
    error "Invalid tenant name: $TENANT_NAME"
    error "Expected lowercase alphanumeric + hyphens, 1-63 characters."
    exit 1
fi

STORAGE_ROOT="${STORAGE_ROOT:-/opt/tenant-data}"
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_MASTER_DB="${MYSQL_MASTER_DB:-zatca_master}"
MYSQL_TENANT_HOST="${MYSQL_TENANT_HOST:-%}"
DOKKU_CONTAINER="${DOKKU_CONTAINER:-dokku}"

BACKEND_APP="${TENANT_NAME}-backend"
FRONTEND_APP="${TENANT_NAME}-frontend"
TENANT_NETWORK="tenant-${TENANT_NAME}"
TENANT_DB_NAME="tenant_${TENANT_NAME//-/_}"
TENANT_DB_USER="usr_${TENANT_NAME//-/_}"

LOG_DIR="${LOG_DIR:-${PROJECT_DIR}/logs}"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="${LOG_DIR}/cleanup-broken-tenant-${TENANT_NAME}-$(date +%Y%m%d-%H%M%S).log"
if [ -w "$LOG_DIR" ] && ! $DRY_RUN; then
    exec > >(tee -a "$LOG_FILE") 2>&1
    info "Logging to: $LOG_FILE"
fi

run() {
    if $DRY_RUN; then
        printf '[dry-run]'
        printf ' %q' "$@"
        printf '\n'
        return 0
    fi
    "$@"
}

run_dokku() {
    if $DRY_RUN; then
        printf '[dry-run] dokku'
        printf ' %q' "$@"
        printf '\n'
        return 0
    fi
    dokku "$@"
}

app_exists() {
    $DRY_RUN && return 0
    dokku apps:exists "$1" >/dev/null 2>&1
}

docker_exec_root() {
    run docker exec -u root "$DOKKU_CONTAINER" "$@"
}

repair_storage_registry_permissions() {
    if $SKIP_STORAGE_REPAIR; then
        warn "Skipping Dokku storage-registry repair."
        return 0
    fi

    log "Repairing Dokku storage-registry permissions..."
    if $DRY_RUN; then
        info "[dry-run] would chown/chmod /var/lib/dokku/data/storage-registry inside $DOKKU_CONTAINER"
        return 0
    fi

    ensure_dokku_running

    if ! docker exec "$DOKKU_CONTAINER" test -d /var/lib/dokku/data/storage-registry 2>/dev/null; then
        warn "Dokku storage registry directory was not found; skipping repair."
        return 0
    fi

    docker_exec_root bash -lc '
set -euo pipefail
registry=/var/lib/dokku/data/storage-registry
chown -R dokku:dokku "$registry" || true
find "$registry" -type d -exec chmod 755 {} + || true
find "$registry" -type f -exec chmod 644 {} + || true
'
}

remove_tenant_registry_leftovers() {
    log "Removing stale Dokku storage-registry entries for ${TENANT_NAME}..."
    if $DRY_RUN; then
        info "[dry-run] would remove registry references for $BACKEND_APP, $FRONTEND_APP, and $STORAGE_ROOT/$TENANT_NAME"
        return 0
    fi

    ensure_dokku_running

    if ! docker exec "$DOKKU_CONTAINER" test -d /var/lib/dokku/data/storage-registry 2>/dev/null; then
        warn "Dokku storage registry directory was not found; skipping stale registry cleanup."
        return 0
    fi

    docker_exec_root bash -s -- "$BACKEND_APP" "$FRONTEND_APP" "$STORAGE_ROOT/$TENANT_NAME" <<'BASH'
set -euo pipefail
backend_app="$1"
frontend_app="$2"
tenant_storage="$3"
registry=/var/lib/dokku/data/storage-registry

for app in "$backend_app" "$frontend_app"; do
    find "$registry" -depth \( -name "$app" -o -name "$app.json" -o -path "*/$app/*" \) -print -exec rm -rf {} + 2>/dev/null || true
done

if [ -d "$registry/entries" ]; then
    while IFS= read -r -d '' file; do
        if grep -Fq "$tenant_storage" "$file" || grep -Fq "$backend_app" "$file" || grep -Fq "$frontend_app" "$file"; then
            echo "$file"
            rm -f "$file"
        fi
    done < <(find "$registry/entries" -type f -name '*.json' -print0 2>/dev/null)
fi
BASH
}

unmount_known_storage() {
    local app="$1"

    app_exists "$app" || return 0

    info "Unmounting known storage from $app"
    run_dokku storage:unmount "$app" "$STORAGE_ROOT/$TENANT_NAME/uploads:/app/uploads" >/dev/null 2>&1 || true
    run_dokku storage:unmount "$app" "$STORAGE_ROOT/$TENANT_NAME/data:/app/data" >/dev/null 2>&1 || true
}

destroy_app() {
    local app="$1"

    if ! app_exists "$app"; then
        info "App $app does not exist."
        return 0
    fi

    log "Destroying app: $app"
    run_dokku ps:stop "$app" >/dev/null 2>&1 || true
    if ! run_dokku apps:destroy "$app" --force; then
        warn "dokku apps:destroy failed for $app; repairing registry and retrying once."
        repair_storage_registry_permissions
        remove_tenant_registry_leftovers
        run_dokku apps:destroy "$app" --force || warn "Could not fully destroy $app through Dokku; removing common leftovers."
    fi
}

remove_common_dokku_leftovers() {
    log "Removing common Dokku filesystem/image leftovers..."
    if $DRY_RUN; then
        info "[dry-run] would remove common Dokku files, containers, and local images for $BACKEND_APP / $FRONTEND_APP"
        return 0
    fi

    ensure_dokku_running

    docker_exec_root bash -s -- "$BACKEND_APP" "$FRONTEND_APP" <<'BASH'
set -euo pipefail
for app in "$@"; do
    rm -rf "/home/dokku/$app" \
           "/var/lib/dokku/data/storage/$app" \
           "/var/lib/dokku/data/storage-registry/apps/$app" \
           "/var/lib/dokku/data/ps/$app" \
           "/var/lib/dokku/data/checks/$app" \
           "/var/lib/dokku/data/nginx-vhosts/$app" 2>/dev/null || true
done
BASH

    run docker rm -f "$BACKEND_APP.web.1" "$FRONTEND_APP.web.1" >/dev/null 2>&1 || true
    run docker rmi "dokku/$BACKEND_APP:latest" "dokku/$FRONTEND_APP:latest" >/dev/null 2>&1 || true
}

drop_database() {
    if ! mysql_admin_configured; then
        warn "MYSQL_ADMIN_PASSWORD not set; skipping tenant DB/user cleanup."
        return 0
    fi

    log "Dropping MySQL database/user: $TENANT_DB_NAME / $TENANT_DB_USER@'$MYSQL_TENANT_HOST'"
    if $DRY_RUN; then
        info "[dry-run] would drop database/user and disable master tenant row"
        return 0
    fi

    run_mysql <<SQLEOF 2>/dev/null || warn "Tenant database/user cleanup failed or was already clean."
DROP DATABASE IF EXISTS \`${TENANT_DB_NAME}\`;
DROP USER IF EXISTS '${TENANT_DB_USER}'@'${MYSQL_TENANT_HOST}';
SQLEOF

    run_mysql "$MYSQL_MASTER_DB" <<SQLEOF 2>/dev/null || true
UPDATE tenant SET enabled=0 WHERE db_name='${TENANT_DB_NAME}';
DELETE FROM tenant WHERE db_name='${TENANT_DB_NAME}' AND name='${TENANT_NAME}';
SQLEOF
}

remove_host_nginx_vhost() {
    local nginx_conf_dir="${NGINX_CONF_DIR:-/etc/nginx/dokku-tenants}"
    if [ -f "$nginx_conf_dir/${TENANT_NAME}.conf" ]; then
        log "Removing host nginx vhost: $nginx_conf_dir/${TENANT_NAME}.conf"
        run rm -f "$nginx_conf_dir/${TENANT_NAME}.conf"
        warn "Reload host nginx if this server uses per-tenant vhosts: nginx -t && systemctl reload nginx"
    fi
}

remove_network() {
    log "Removing tenant docker network: $TENANT_NETWORK"
    run docker network rm "$TENANT_NETWORK" >/dev/null 2>&1 || true
}

remove_storage_data() {
    if ! $DELETE_DATA; then
        warn "Persistent tenant data preserved at: $STORAGE_ROOT/$TENANT_NAME"
        warn "Run with --delete-data for a full data cleanup."
        return 0
    fi

    log "Deleting persistent tenant data: $STORAGE_ROOT/$TENANT_NAME"
    if $DRY_RUN; then
        info "[dry-run] would delete tenant data from the runner and Dokku container namespaces"
        return 0
    fi

    run rm -rf "${STORAGE_ROOT:?}/$TENANT_NAME" 2>/dev/null || true
    ensure_dokku_running
    docker_exec_root rm -rf "${STORAGE_ROOT:?}/$TENANT_NAME" 2>/dev/null || true
}

echo ""
info "=== Broken Tenant Cleanup Plan ==="
info "  Tenant:       $TENANT_NAME"
info "  Apps:         $BACKEND_APP, $FRONTEND_APP"
info "  Database:     $TENANT_DB_NAME / $TENANT_DB_USER"
info "  Network:      $TENANT_NETWORK"
info "  Storage:      $STORAGE_ROOT/$TENANT_NAME"
info "  Delete data:  $DELETE_DATA"
info "  Dry run:      $DRY_RUN"
echo ""

if ! $FORCE; then
    warn "About to force-clean tenant: $TENANT_NAME"
    read -rp "Type 'yes' to confirm: " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Cancelled."
        exit 0
    fi
fi

repair_storage_registry_permissions
unmount_known_storage "$BACKEND_APP"
unmount_known_storage "$FRONTEND_APP"
destroy_app "$BACKEND_APP"
destroy_app "$FRONTEND_APP"
remove_tenant_registry_leftovers
remove_common_dokku_leftovers
drop_database
remove_host_nginx_vhost
remove_network
remove_storage_data

echo ""
log "Broken tenant '$TENANT_NAME' cleanup complete."
log "You can now recreate it with scripts/create-tenant.sh."