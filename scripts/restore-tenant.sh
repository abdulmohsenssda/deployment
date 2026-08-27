#!/usr/bin/env bash
# =============================================================================
# restore-tenant.sh — Restore / roll a tenant back to a previous backup
# =============================================================================
# Restores a tenant's persistent files and/or MySQL database from a backup set
# produced by backup-tenant.sh. Any historical version can be restored, which
# doubles as a safe rollback: before overwriting anything, a fresh verified
# safety backup (origin=auto, owner=rollback-safety) is taken so the operator
# can undo the restore itself.
#
# Usage:
#   ./scripts/restore-tenant.sh <tenant> --from <backup-id> [options]
#
# Options:
#   --from <backup-id>    Backup set to restore ("<tenant>_<timestamp>").
#   --files-only          Restore only persistent files.
#   --db-only             Restore only the MySQL database.
#   --no-safety-backup    Skip the pre-restore safety backup (NOT recommended).
#   --yes                 Do not prompt for confirmation.
#   --dry-run             Print the plan without changing anything.
#
# The restore refuses to run against a backup whose artifacts fail integrity
# verification, so a corrupt backup can never clobber good data.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib.sh"

CONFIG_FILE="$PROJECT_DIR/config.env"
FROM_ID=""
FILES_ONLY=0
DB_ONLY=0
SAFETY_BACKUP=1
ASSUME_YES=0
DRY_RUN=0
TENANT_ARG=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --config)           CONFIG_FILE="$2"; shift 2 ;;
        --from|--to)        FROM_ID="$2"; shift 2 ;;
        --files-only)       FILES_ONLY=1; shift ;;
        --db-only)          DB_ONLY=1; shift ;;
        --no-safety-backup) SAFETY_BACKUP=0; shift ;;
        --yes|-y)           ASSUME_YES=1; shift ;;
        --dry-run)          DRY_RUN=1; shift ;;
        -*)                 echo "Unknown option: $1" >&2; exit 1 ;;
        *)                  [ -z "$TENANT_ARG" ] && TENANT_ARG="$1"; shift ;;
    esac
done

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }
info() { echo -e "${BLUE}[i]${NC} $*"; }

[ -n "$TENANT_ARG" ] || { err "usage: $0 <tenant> --from <backup-id>"; exit 1; }
[ -n "$FROM_ID" ] || { err "--from <backup-id> is required"; exit 1; }
valid_backup_id "$FROM_ID" || { err "Invalid backup id '$FROM_ID'"; exit 1; }
if [ "$FILES_ONLY" -eq 1 ] && [ "$DB_ONLY" -eq 1 ]; then
    err "--files-only and --db-only are mutually exclusive"; exit 1
fi

[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
STORAGE_ROOT="${STORAGE_ROOT:-/opt/tenant-data}"
BACKUP_DIR="${BACKUP_DIR:-/opt/tenant-backups}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"

TENANT="$(tenant_full_name "$TENANT_ARG")" || exit 1
META="$BACKUP_DIR/${FROM_ID}.meta.json"
[ -f "$META" ] || { err "No backup with id '$FROM_ID' in $BACKUP_DIR"; exit 1; }

BACKUP_TENANT="$(backup_meta_field "$META" tenant || echo '')"
if [ "$BACKUP_TENANT" != "$TENANT" ]; then
    err "Backup '$FROM_ID' belongs to tenant '$BACKUP_TENANT', not '$TENANT'. Refusing to cross-restore."
    exit 1
fi

FILES_ARTIFACT="$(backup_meta_field "$META" files_artifact || echo '')"
DB_ARTIFACT="$(backup_meta_field "$META" db_artifact || echo '')"
FILES_PATH=""
DB_PATH=""
if [ -n "$FILES_ARTIFACT" ]; then
    FILES_PATH="$(backup_artifact_path "$FILES_ARTIFACT")" || {
        err "Invalid files artifact in backup '$FROM_ID'"
        exit 1
    }
fi
if [ -n "$DB_ARTIFACT" ]; then
    DB_PATH="$(backup_artifact_path "$DB_ARTIFACT")" || {
        err "Invalid DB artifact in backup '$FROM_ID'"
        exit 1
    }
fi

# Decide what to restore based on flags and what the backup actually contains.
RESTORE_FILES=0
RESTORE_DB=0
[ "$DB_ONLY" -eq 1 ] || { [ -n "$FILES_ARTIFACT" ] && RESTORE_FILES=1; }
[ "$FILES_ONLY" -eq 1 ] || { [ -n "$DB_ARTIFACT" ] && RESTORE_DB=1; }
if [ "$RESTORE_FILES" -eq 0 ] && [ "$RESTORE_DB" -eq 0 ]; then
    err "Nothing to restore for '$FROM_ID' with the given flags."
    exit 1
fi

# Never restore from a corrupt backup.
if [ "$RESTORE_FILES" -eq 1 ]; then
    verify_gzip_artifact "$FILES_PATH" || { err "Files archive is corrupt: $FILES_ARTIFACT"; exit 1; }
fi
if [ "$RESTORE_DB" -eq 1 ]; then
    verify_gzip_artifact "$DB_PATH" || { err "MySQL dump is corrupt: $DB_ARTIFACT"; exit 1; }
fi

info "Restore plan for tenant '$TENANT' from backup '$FROM_ID':"
[ "$RESTORE_FILES" -eq 1 ] && info "  files ← $FILES_ARTIFACT → $STORAGE_ROOT/$TENANT"
[ "$RESTORE_DB" -eq 1 ]    && info "  db    ← $DB_ARTIFACT → database tenant_${TENANT//-/_}"
[ "$SAFETY_BACKUP" -eq 1 ] && info "  safety backup of current state will be taken first"

if [ "$DRY_RUN" -eq 1 ]; then
    log "Dry run — no changes made."
    exit 0
fi

if [ "$ASSUME_YES" -ne 1 ] && [ -t 0 ]; then
    printf 'Proceed with restore? This overwrites current tenant state [y/N] '
    read -r reply
    case "$reply" in y|Y|yes|YES) ;; *) warn "Aborted."; exit 0 ;; esac
fi

# Safety backup of the current state so the restore itself is reversible.
if [ "$SAFETY_BACKUP" -eq 1 ]; then
    log "Taking verified safety backup of current state before restore..."
    if ! bash "$SCRIPT_DIR/backup-tenant.sh" "$TENANT_ARG" \
            --origin auto --owner rollback-safety --require-verified --no-prune \
            --config "$CONFIG_FILE"; then
        err "Safety backup failed verification — aborting restore to protect current data."
        exit 1
    fi
fi

# Restore files: extract into STORAGE_ROOT so the "<tenant>/" prefix inside the
# archive lands back at STORAGE_ROOT/<tenant>.
if [ "$RESTORE_FILES" -eq 1 ]; then
    log "Restoring files into $STORAGE_ROOT ..."
    mkdir -p "$STORAGE_ROOT"
    tar xzf "$FILES_PATH" -C "$STORAGE_ROOT"
    log "Files restored."
fi

# Restore database: pipe the gunzipped dump into the tenant DB.
if [ "$RESTORE_DB" -eq 1 ]; then
    local_db="tenant_${TENANT//-/_}"
    if [ -z "$MYSQL_ROOT_PASSWORD" ] || [ "$MYSQL_ROOT_PASSWORD" = "changeme" ]; then
        err "MYSQL_ROOT_PASSWORD not configured — cannot restore database."
        exit 1
    fi
    log "Restoring MySQL database '$local_db' ..."
    run_mysql -e "CREATE DATABASE IF NOT EXISTS \`${local_db}\`"
    gunzip -c "$DB_PATH" | run_mysql "$local_db"
    log "Database restored."
fi

log "Restore of tenant '$TENANT' from '$FROM_ID' complete."
warn "Restart the tenant apps if needed: deployctl tenant update $TENANT_ARG --restart"
