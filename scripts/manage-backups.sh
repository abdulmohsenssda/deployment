#!/usr/bin/env bash
# =============================================================================
# manage-backups.sh — List, verify, delete, and prune tenant backups
# =============================================================================
# Backups are managed as "sets": a manifest sidecar
# "<tenant>_<timestamp>.meta.json" plus its .tar.gz / .sql.gz artifacts, all in
# BACKUP_DIR. This script is the allow-listed surface the dashboard uses to let
# operators inspect and clean up backups without arbitrary shell access.
#
# Usage:
#   ./scripts/manage-backups.sh list [<tenant>] [--json]
#   ./scripts/manage-backups.sh path <backup-id>          # print artifact paths
#   ./scripts/manage-backups.sh verify <backup-id>
#   ./scripts/manage-backups.sh delete <backup-id> [--owner <name>] [--force]
#   ./scripts/manage-backups.sh prune [--retention-days <n>] [--dry-run]
#
# Ownership rules:
#   * A user backup (origin=user) may only be deleted by its owner, unless
#     --force is given (operator override).
#   * prune only ever deletes auto-origin backups; user backups are protected.
#
# backup-id is "<tenant>_<timestamp>" (the manifest base name).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib.sh"

CONFIG_FILE="$PROJECT_DIR/config.env"
JSON=0
FORCE=0
DRY_RUN=0
OWNER_FILTER=""
RETENTION_OVERRIDE=""
POSITIONAL=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --config)         CONFIG_FILE="$2"; shift 2 ;;
        --json)           JSON=1; shift ;;
        --force)          FORCE=1; shift ;;
        --dry-run)        DRY_RUN=1; shift ;;
        --owner)          OWNER_FILTER="$2"; shift 2 ;;
        --retention-days) RETENTION_OVERRIDE="$2"; shift 2 ;;
        *)                POSITIONAL+=("$1"); shift ;;
    esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
BACKUP_DIR="${BACKUP_DIR:-/opt/tenant-backups}"
RETENTION_DAYS="${RETENTION_OVERRIDE:-${BACKUP_RETENTION_DAYS:-30}}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }

meta_for_id() { printf '%s/%s.meta.json' "$BACKUP_DIR" "$1"; }

require_meta() {
    local id="$1" meta
    if ! valid_backup_id "$id"; then
        err "Invalid backup id '$id'"
        return 1
    fi
    meta="$(meta_for_id "$id")"
    if [ ! -f "$meta" ]; then
        err "No backup with id '$id' in $BACKUP_DIR"
        return 1
    fi
    printf '%s' "$meta"
}

human_size() {
    local f="$1"
    [ -f "$f" ] || { printf '-'; return; }
    du -h "$f" 2>/dev/null | cut -f1
}

cmd_list() {
    local tenant_filter="${1:-}"
    mkdir -p "$BACKUP_DIR"
    local metas=()
    while IFS= read -r m; do [ -n "$m" ] && metas+=("$m"); done \
        < <(find "$BACKUP_DIR" -maxdepth 1 -name "*.meta.json" 2>/dev/null | sort)

    if [ "$JSON" -eq 1 ]; then
        printf '['
        local first=1 m
        for m in "${metas[@]:-}"; do
            [ -n "$m" ] || continue
            local tenant origin
            tenant="$(backup_meta_field "$m" tenant || echo '')"
            [ -n "$tenant_filter" ] && [ "$tenant" != "$tenant_filter" ] && continue
            origin="$(backup_meta_field "$m" owner || echo '')"
            [ -n "$OWNER_FILTER" ] && [ "$origin" != "$OWNER_FILTER" ] && continue
            [ "$first" -eq 1 ] || printf ','
            first=0
            # Emit the manifest content verbatim (already valid JSON object).
            cat "$m"
        done
        printf ']\n'
        return 0
    fi

    printf '%-28s %-10s %-8s %-12s %-8s %s\n' "ID" "ORIGIN" "OWNER" "TIMESTAMP" "VERIFIED" "ARTIFACTS"
    local m
    for m in "${metas[@]:-}"; do
        [ -n "$m" ] || continue
        local id tenant ts origin owner verified files db
        id="$(backup_meta_field "$m" id || echo '')"
        tenant="$(backup_meta_field "$m" tenant || echo '')"
        [ -n "$tenant_filter" ] && [ "$tenant" != "$tenant_filter" ] && continue
        owner="$(backup_meta_field "$m" owner || echo '')"
        [ -n "$OWNER_FILTER" ] && [ "$owner" != "$OWNER_FILTER" ] && continue
        ts="$(backup_meta_field "$m" timestamp || echo '')"
        origin="$(backup_meta_field "$m" origin || echo '')"
        verified="$(sed -n 's/.*"verified"[[:space:]]*:[[:space:]]*\([a-z]*\).*/\1/p' "$m" | head -n1)"
        files="$(backup_meta_field "$m" files_artifact || echo '')"
        db="$(backup_meta_field "$m" db_artifact || echo '')"
        local artifacts=""
        if [ -n "$files" ] && backup_artifact_path "$files" >/dev/null; then
            artifacts="files($(human_size "$BACKUP_DIR/$files"))"
        fi
        if [ -n "$db" ] && backup_artifact_path "$db" >/dev/null; then
            artifacts="${artifacts:+$artifacts }db($(human_size "$BACKUP_DIR/$db"))"
        fi
        printf '%-28s %-10s %-8s %-12s %-8s %s\n' "$id" "$origin" "$owner" "$ts" "$verified" "${artifacts:--}"
    done
}

cmd_path() {
    local id="$1" meta files db path
    meta="$(require_meta "$id")" || return 1
    files="$(backup_meta_field "$meta" files_artifact || echo '')"
    db="$(backup_meta_field "$meta" db_artifact || echo '')"
    if [ -n "$files" ]; then
        path="$(backup_artifact_path "$files")" || { err "Invalid files artifact in '$id'"; return 1; }
        printf '%s\n' "$path"
    fi
    if [ -n "$db" ]; then
        path="$(backup_artifact_path "$db")" || { err "Invalid DB artifact in '$id'"; return 1; }
        printf '%s\n' "$path"
    fi
}

cmd_verify() {
    local id="$1" meta files db path rc=0
    meta="$(require_meta "$id")" || return 1
    files="$(backup_meta_field "$meta" files_artifact || echo '')"
    db="$(backup_meta_field "$meta" db_artifact || echo '')"
    if [ -n "$files" ]; then
        if path="$(backup_artifact_path "$files")"; then
            if verify_gzip_artifact "$path"; then log "files OK: $files"; else err "files CORRUPT: $files"; rc=1; fi
        else
            err "Invalid files artifact in '$id'"
            rc=1
        fi
    fi
    if [ -n "$db" ]; then
        if path="$(backup_artifact_path "$db")"; then
            if verify_gzip_artifact "$path"; then log "db OK: $db"; else err "db CORRUPT: $db"; rc=1; fi
        else
            err "Invalid DB artifact in '$id'"
            rc=1
        fi
    fi
    [ -n "$files" ] || [ -n "$db" ] || rc=1
    return "$rc"
}

cmd_delete() {
    local id="$1" meta origin owner files db files_path db_path
    meta="$(require_meta "$id")" || return 1
    origin="$(backup_meta_field "$meta" origin || echo auto)"
    owner="$(backup_meta_field "$meta" owner || echo '')"

    # Ownership check for user backups. Operators can override with --force.
    if [ "$origin" = "user" ] && [ "$FORCE" -ne 1 ]; then
        if [ -z "$OWNER_FILTER" ]; then
            err "Backup '$id' is a user backup owned by '$owner'. Pass --owner $owner (or --force) to delete."
            return 1
        fi
        if [ "$OWNER_FILTER" != "$owner" ]; then
            err "Backup '$id' is owned by '$owner', not '$OWNER_FILTER'. Refusing to delete."
            return 1
        fi
    fi

    files="$(backup_meta_field "$meta" files_artifact || echo '')"
    db="$(backup_meta_field "$meta" db_artifact || echo '')"
    if [ -n "$files" ]; then
        files_path="$(backup_artifact_path "$files")" || { err "Invalid files artifact in '$id'"; return 1; }
        rm -f "$files_path"
    fi
    if [ -n "$db" ]; then
        db_path="$(backup_artifact_path "$db")" || { err "Invalid DB artifact in '$id'"; return 1; }
        rm -f "$db_path"
    fi
    rm -f "$meta"
    log "Deleted backup '$id' (origin=$origin owner=$owner)"
}

cmd_prune() {
    local days="$RETENTION_DAYS"
    [ "$days" -gt 0 ] 2>/dev/null || { warn "retention days is 0 — nothing pruned"; return 0; }
    local meta pruned=0
    while IFS= read -r meta; do
        [ -n "$meta" ] || continue
        local origin id files db files_path db_path
        origin="$(backup_meta_field "$meta" origin || echo auto)"
        [ "$origin" = "user" ] && continue   # protected
        id="$(backup_meta_field "$meta" id || echo '')"
        files="$(backup_meta_field "$meta" files_artifact || echo '')"
        db="$(backup_meta_field "$meta" db_artifact || echo '')"
        if [ "$DRY_RUN" -eq 1 ]; then
            warn "[dry-run] would prune $id (older than ${days}d)"
        else
            if [ -n "$files" ]; then
                files_path="$(backup_artifact_path "$files")" || { err "Invalid files artifact in '$id'; skipping"; continue; }
                rm -f "$files_path"
            fi
            if [ -n "$db" ]; then
                db_path="$(backup_artifact_path "$db")" || { err "Invalid DB artifact in '$id'; skipping"; continue; }
                rm -f "$db_path"
            fi
            rm -f "$meta"
            warn "Pruned $id (older than ${days}d)"
        fi
        pruned=$((pruned + 1))
    done < <(find "$BACKUP_DIR" -maxdepth 1 -name "*.meta.json" -mtime "+${days}" 2>/dev/null | sort)
    log "Prune complete: ${pruned} auto backup(s) matched (user backups protected)."
}

ACTION="${1:-list}"
shift || true
case "$ACTION" in
    list)   cmd_list "${1:-}" ;;
    path)   [ -n "${1:-}" ] || { err "usage: path <backup-id>"; exit 1; }; cmd_path "$1" ;;
    verify) [ -n "${1:-}" ] || { err "usage: verify <backup-id>"; exit 1; }; cmd_verify "$1" ;;
    delete) [ -n "${1:-}" ] || { err "usage: delete <backup-id>"; exit 1; }; cmd_delete "$1" ;;
    prune)  cmd_prune ;;
    *)      err "unknown action: $ACTION (expected list|path|verify|delete|prune)"; exit 1 ;;
esac
