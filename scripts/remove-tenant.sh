#!/usr/bin/env bash
# =============================================================================
# remove-tenant.sh — Fully remove a Dokku tenant. Leaves no traces by default.
# =============================================================================
# Deletes: Dokku apps, MySQL DB + user, master DB row, tenantstate JSON,
#          persistent data, backup artifacts, host nginx vhost.
# Usage:
#   ./scripts/remove-tenant.sh <tenant-name> [--keep-data] [--keep-backups] [--force]
#   ./scripts/remove-tenant.sh <tenant-name> --config /opt/deployment/config.dev.env
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; }

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
KEEP_DATA=false
KEEP_BACKUPS=false
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --delete-data) shift ;;               # deprecated: data deletion is now the default
        --keep-data)   KEEP_DATA=true; shift ;;
        --keep-backups) KEEP_BACKUPS=true; shift ;;
        --force)       FORCE=true; shift ;;
        --config)      shift 2 ;;  # already parsed above
        -*)            error "Unknown option: $1"; exit 1 ;;
        *)             [ -z "$TENANT_NAME" ] && TENANT_NAME="$1"; shift ;;
    esac
done

if [ -z "$TENANT_NAME" ]; then
    error "Usage: $0 <tenant-name> [--keep-data] [--keep-backups] [--force]"
    exit 1
fi

TENANT_NAME="$(tenant_full_name "$TENANT_NAME")" || exit 1

STORAGE_ROOT="${STORAGE_ROOT:-/opt/tenant-data}"
BACKUP_DIR="${BACKUP_DIR:-/opt/tenant-backups}"
TENANT_STATE_DIR="${TENANT_STATE_DIR:-/opt/tenant-state}"
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_MASTER_DB="${MYSQL_MASTER_DB:-zatca_master}"
BACKEND_APP="${TENANT_NAME}-backend"
FRONTEND_APP="${TENANT_NAME}-frontend"

# Check apps exist
BACKEND_EXISTS=false
FRONTEND_EXISTS=false
dokku apps:exists "$BACKEND_APP" 2>/dev/null && BACKEND_EXISTS=true
dokku apps:exists "$FRONTEND_APP" 2>/dev/null && FRONTEND_EXISTS=true

if ! $BACKEND_EXISTS && ! $FRONTEND_EXISTS; then
    error "Tenant '$TENANT_NAME' not found (no Dokku apps)."
    exit 1
fi

# ---- Confirmation ----
if ! $FORCE; then
    echo ""
    warn "About to DESTROY tenant: $TENANT_NAME"
    warn "  Apps:          $BACKEND_APP, $FRONTEND_APP"
    warn "  Database:      tenant_${TENANT_NAME//-/_} + user"
    warn "  Master DB row: DELETED (dashboard will no longer show this tenant)"
    warn "  Tenant state:  $TENANT_STATE_DIR/$TENANT_NAME.json"
    $KEEP_DATA    && warn "  Data:          KEPT at $STORAGE_ROOT/$TENANT_NAME/ (--keep-data)"    || warn "  Data:          DELETED at $STORAGE_ROOT/$TENANT_NAME/"
    $KEEP_BACKUPS && warn "  Backups:       KEPT at $BACKUP_DIR/${TENANT_NAME}_* (--keep-backups)" || warn "  Backups:       DELETED at $BACKUP_DIR/${TENANT_NAME}_*"
    echo ""
    read -rp "Type 'yes' to confirm: " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Cancelled."
        exit 0
    fi
fi

# ---- Drop tenant database and user from external MySQL ----
TENANT_DB_NAME="tenant_${TENANT_NAME//-/_}"
TENANT_DB_USER="usr_${TENANT_NAME//-/_}"

if mysql_admin_configured; then
    log "Dropping MySQL database: $TENANT_DB_NAME"
    MYSQL_TENANT_HOST="${MYSQL_TENANT_HOST:-%}"
    run_mysql <<SQLEOF 2>/dev/null || warn "Database $TENANT_DB_NAME not found (may already be dropped)."
DROP DATABASE IF EXISTS \`${TENANT_DB_NAME}\`;
DROP USER IF EXISTS '${TENANT_DB_USER}'@'${MYSQL_TENANT_HOST}';
DROP USER IF EXISTS '${TENANT_DB_USER}'@'localhost';
SQLEOF

    # Delete row from master DB so the dashboard fleet view no longer shows
    # a ghost tenant. Previously this only set enabled=0, leaving a stale row.
    run_mysql "$MYSQL_MASTER_DB" <<SQLEOF 2>/dev/null || true
DELETE FROM tenant WHERE db_name='${TENANT_DB_NAME}';
SQLEOF
    log "Tenant removed from master database."
else
    warn "MYSQL_ADMIN_PASSWORD not set — skipping database cleanup."
fi

# ---- Remove host nginx vhost (NGINX_MODE=behind-nginx) ----
NGINX_CONF_DIR="${NGINX_CONF_DIR:-/etc/nginx/dokku-tenants}"
if [ -f "$NGINX_CONF_DIR/${TENANT_NAME}.conf" ]; then
    log "Removing host nginx vhost: $NGINX_CONF_DIR/${TENANT_NAME}.conf"
    rm -f "$NGINX_CONF_DIR/${TENANT_NAME}.conf"
    warn "Reload host nginx to drop the vhost: sudo nginx -t && sudo systemctl reload nginx"
fi

# ---- Destroy Dokku apps ----
if $BACKEND_EXISTS; then
    log "Destroying app: $BACKEND_APP"
    dokku apps:destroy "$BACKEND_APP" --force
fi

if $FRONTEND_EXISTS; then
    log "Destroying app: $FRONTEND_APP"
    dokku apps:destroy "$FRONTEND_APP" --force
fi

# ---- Remove persistent data ----
if ! $KEEP_DATA && [ -d "$STORAGE_ROOT/$TENANT_NAME" ]; then
    log "Deleting persistent data: $STORAGE_ROOT/$TENANT_NAME/"
    rm -rf "${STORAGE_ROOT:?}/$TENANT_NAME"
fi

# ---- Remove tenant state file (per-tenant auto-redeploy toggle, etc.) ----
if [ -f "$TENANT_STATE_DIR/$TENANT_NAME.json" ]; then
    log "Deleting tenant state: $TENANT_STATE_DIR/$TENANT_NAME.json"
    rm -f "$TENANT_STATE_DIR/$TENANT_NAME.json"
fi

# ---- Remove backup artifacts ----
if ! $KEEP_BACKUPS && [ -d "$BACKUP_DIR" ]; then
    # Match every backup-tenant.sh artifact for this tenant:
    #   <tenant>_files_<timestamp>.tar.gz
    #   <tenant>_mysql_<timestamp>.sql.gz
    #   <tenant>_<timestamp>.meta.json
    _removed=0
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        rm -f "$f"
        _removed=$((_removed + 1))
    done < <(find "$BACKUP_DIR" -maxdepth 1 -type f \
        \( -name "${TENANT_NAME}_files_*.tar.gz" \
        -o -name "${TENANT_NAME}_mysql_*.sql.gz" \
        -o -name "${TENANT_NAME}_*.meta.json" \) 2>/dev/null)
    if [ "$_removed" -gt 0 ]; then
        log "Deleted $_removed backup artifact(s) for $TENANT_NAME."
    fi
fi

echo ""
log "Tenant '$TENANT_NAME' removed."
if $KEEP_DATA && [ -d "$STORAGE_ROOT/$TENANT_NAME" ]; then
    warn "Persistent data preserved at: $STORAGE_ROOT/$TENANT_NAME/  (--keep-data)"
fi
if $KEEP_BACKUPS; then
    warn "Backups preserved at: $BACKUP_DIR/${TENANT_NAME}_*  (--keep-backups)"
fi
