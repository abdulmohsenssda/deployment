#!/usr/bin/env bash
# =============================================================================
# backup-tenant.sh — Backup tenant persistent data and/or database
# =============================================================================
# Usage:
#   ./scripts/backup-tenant.sh <tenant-name>
#   ./scripts/backup-tenant.sh --all
#   ./scripts/backup-tenant.sh <tenant-name> --origin user --owner alice
#   ./scripts/backup-tenant.sh <tenant-name> --origin user --owner alice --label "before release"
#   ./scripts/backup-tenant.sh --all --config /opt/deployment/config.dev.env
#
# Options:
#   --origin user|auto    Who created this backup. Default: auto.
#                         user backups are protected from policy deletion;
#                         auto backups are pruned by the retention policy.
#   --owner <name>        Owner tag stored in the manifest (default: system,
#                         or BACKUP_OWNER from the environment).
#   --label <text>        Optional human-readable label stored in the manifest.
#   --retention-days <n>  Override BACKUP_RETENTION_DAYS for the prune step.
#   --no-prune            Skip the retention prune at the end of this run.
#   --require-verified    Exit non-zero if any produced artifact fails
#                         integrity verification (used by automatic deploys
#                         that must have a verified backup before rolling out).
#
# Each run writes a manifest sidecar "<tenant>_<timestamp>.meta.json" so the
# backup-management and restore tooling can list, protect, and restore sets.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib.sh"

# Parse flags early (before sourcing config for --config).
CONFIG_FILE="$PROJECT_DIR/config.env"
ORIGIN="auto"
OWNER="${BACKUP_OWNER:-system}"
OWNER_EXPLICIT=0
LABEL=""
LABEL_EXPLICIT=0
RETENTION_OVERRIDE=""
DO_PRUNE=1
REQUIRE_VERIFIED=0
ARGS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --config)           CONFIG_FILE="$2"; shift 2 ;;
        --origin)           ORIGIN="$2"; shift 2 ;;
        --owner)            OWNER="$2"; OWNER_EXPLICIT=1; shift 2 ;;
        --label)            LABEL="$2"; LABEL_EXPLICIT=1; shift 2 ;;
        --retention-days)   RETENTION_OVERRIDE="$2"; shift 2 ;;
        --no-prune)         DO_PRUNE=0; shift ;;
        --require-verified) REQUIRE_VERIFIED=1; shift ;;
        *)                  ARGS+=("$1"); shift ;;
    esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

case "$ORIGIN" in
    user|auto) ;;
    *) echo "Invalid --origin '$ORIGIN' (expected user|auto)" >&2; exit 2 ;;
esac

[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
if [ "$OWNER_EXPLICIT" -eq 0 ]; then
    OWNER="${BACKUP_OWNER:-system}"
fi
if [ "$LABEL_EXPLICIT" -eq 0 ]; then
    LABEL="${BACKUP_LABEL:-}"
fi

STORAGE_ROOT="${STORAGE_ROOT:-/opt/tenant-data}"
BACKUP_DIR="${BACKUP_DIR:-/opt/tenant-backups}"
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
RETENTION_DAYS="${RETENTION_OVERRIDE:-${BACKUP_RETENTION_DAYS:-30}}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }

if [ "${#LABEL}" -gt 120 ] || [[ "$LABEL" =~ [[:cntrl:]] ]]; then
    err "Backup label must be at most 120 characters and contain no control characters."
    exit 2
fi

mkdir -p "$BACKUP_DIR"

# Tracks whether every artifact of the most recent tenant passed verification.
LAST_VERIFIED="true"

backup_tenant() {
    local tenant="$1"
    local source="$STORAGE_ROOT/$tenant"
    local files_dest="" db_dest=""
    LAST_VERIFIED="true"

    # Backup files
    if [ -d "$source" ]; then
        files_dest="$BACKUP_DIR/${tenant}_files_${TIMESTAMP}.tar.gz"
        log "Backing up files: $tenant → $files_dest"
        tar czf "$files_dest" -C "$STORAGE_ROOT" "$tenant"
        echo "  Size: $(du -h "$files_dest" | cut -f1)"
        if verify_gzip_artifact "$files_dest"; then
            log "  Verified files archive OK"
        else
            err "  Files archive failed verification: $files_dest"
            LAST_VERIFIED="false"
        fi
    else
        warn "No data directory for tenant '$tenant'."
        LAST_VERIFIED="false"
    fi

    # Backup MySQL database from external server
    local tenant_db="tenant_${tenant//-/_}"
    if mysql_admin_configured; then
        # Check if the database exists
        if run_mysql -e "USE \`${tenant_db}\`" 2>/dev/null; then
            db_dest="$BACKUP_DIR/${tenant}_mysql_${TIMESTAMP}.sql.gz"
            log "Backing up MySQL: $tenant_db → $db_dest"
            if run_mysqldump \
                --single-transaction --routines --triggers "$tenant_db" | gzip > "$db_dest"; then
                echo "  Size: $(du -h "$db_dest" | cut -f1)"
                if verify_gzip_artifact "$db_dest"; then
                    log "  Verified MySQL dump OK"
                else
                    err "  MySQL dump failed verification: $db_dest"
                    LAST_VERIFIED="false"
                fi
            else
                err "  MySQL dump failed: $tenant_db"
                rm -f "$db_dest"
                LAST_VERIFIED="false"
            fi
        else
            warn "MySQL database '$tenant_db' does not exist."
            LAST_VERIFIED="false"
        fi
    else
        warn "MYSQL_ADMIN_PASSWORD is not configured; cannot create SQL backup for '$tenant_db'."
        LAST_VERIFIED="false"
    fi

    # Write the manifest sidecar describing this backup set.
    local meta="$BACKUP_DIR/${tenant}_${TIMESTAMP}.meta.json"
    write_backup_manifest "$meta" "$tenant" "$TIMESTAMP" "$ORIGIN" "$OWNER" \
        "${files_dest:--}" "${db_dest:--}" "$LAST_VERIFIED" "$LABEL"
    log "Manifest: $meta (origin=$ORIGIN owner=$OWNER verified=$LAST_VERIFIED${LABEL:+ label=$LABEL})"
}

OVERALL_VERIFIED="true"

if [ "${1:-}" = "--all" ]; then
    log "Backing up ALL tenants..."
    ALL_APPS=$(dokku apps:list 2>/dev/null | tail -n +2 || true)
    declare -A SEEN
    while IFS= read -r app; do
        if [[ "$app" == *-backend ]]; then
            tenant="${app%-backend}"
            tenant_in_scope "$tenant" || continue
            if [ -z "${SEEN[$tenant]:-}" ]; then
                SEEN["$tenant"]=1
                backup_tenant "$tenant"
                [ "$LAST_VERIFIED" = "true" ] || OVERALL_VERIFIED="false"
            fi
        fi
    done <<< "$ALL_APPS"
elif [ -n "${1:-}" ]; then
    backup_tenant "$(tenant_full_name "$1")"
    [ "$LAST_VERIFIED" = "true" ] || OVERALL_VERIFIED="false"
else
    echo "Usage: $0 <tenant-name> | --all [--origin user|auto] [--owner <name>] [--label <label>]"
    exit 1
fi

# Retention policy: only auto-origin backups are eligible for deletion. Any
# set whose manifest marks origin=user is protected and kept indefinitely.
prune_old_backups() {
    local days="$1"
    [ "$days" -gt 0 ] 2>/dev/null || return 0
    local meta
    while IFS= read -r meta; do
        [ -n "$meta" ] || continue
        local origin
        origin="$(backup_meta_field "$meta" origin || echo auto)"
        if [ "$origin" = "user" ]; then
            continue
        fi
        # Delete the manifest and its artifacts once older than the policy.
        local tenant ts files db
        tenant="$(backup_meta_field "$meta" tenant || echo '')"
        ts="$(backup_meta_field "$meta" timestamp || echo '')"
        files="$(backup_meta_field "$meta" files_artifact || echo '')"
        db="$(backup_meta_field "$meta" db_artifact || echo '')"
        [ -n "$files" ] && rm -f "$BACKUP_DIR/$files"
        [ -n "$db" ] && rm -f "$BACKUP_DIR/$db"
        rm -f "$meta"
        warn "Pruned auto backup ${tenant}_${ts} (older than ${days}d)"
    done < <(find "$BACKUP_DIR" -name "*.meta.json" -mtime "+${days}" 2>/dev/null || true)

    # Legacy artifacts without a manifest (created before manifests existed)
    # are treated as auto and pruned by age, matching the old behavior.
    find "$BACKUP_DIR" -name "*.tar.gz" -mtime "+${days}" 2>/dev/null | while IFS= read -r f; do
        [ -f "${f%.tar.gz}.meta.json" ] || rm -f "$f"
    done
    find "$BACKUP_DIR" -name "*.sql.gz" -mtime "+${days}" 2>/dev/null | while IFS= read -r f; do
        rm -f "$f"
    done
}

if [ "$DO_PRUNE" -eq 1 ]; then
    prune_old_backups "$RETENTION_DAYS"
fi

echo ""
log "Backups stored in: $BACKUP_DIR (retention: ${RETENTION_DAYS}d, user backups protected)"

if [ "$REQUIRE_VERIFIED" -eq 1 ] && [ "$OVERALL_VERIFIED" != "true" ]; then
    err "One or more backup artifacts failed verification and --require-verified was set."
    exit 1
fi
