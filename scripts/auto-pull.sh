#!/usr/bin/env bash
# =============================================================================
# auto-pull.sh — Watch Docker Hub for DEV_TAG and redeploy the dev tenant
# =============================================================================
# This is the AUTO-DEPLOY flow for the dev environment ONLY.
# Production tenants are deployed MANUALLY via deploy-all.sh.
#
# How it works:
#   1. Cron runs this every 2 min.
#   2. We fetch the manifest digest of <image>:DEV_TAG from Docker Hub.
#   3. If it changed since the last run, we redeploy the dev tenant.
#
# Install as cron:
#   sudo crontab -e
#   */2 * * * * /opt/deployment/scripts/auto-pull.sh >> /var/log/auto-pull.log 2>&1
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "[$(date '+%F %T')] ${GREEN}[+]${NC} $*"; }
warn() { echo -e "[$(date '+%F %T')] ${YELLOW}[!]${NC} $*"; }
info() { echo -e "[$(date '+%F %T')] ${BLUE}[i]${NC} $*"; }

CONFIG_FILE="$PROJECT_DIR/config.env"
CHECK_TYPE="both"   # backend | frontend | both

while [[ $# -gt 0 ]]; do
    case "$1" in
        --type)   CHECK_TYPE="$2"; shift 2 ;;
        --config) CONFIG_FILE="$2"; shift 2 ;;
        -*)       echo "Unknown option: $1"; exit 1 ;;
        *)        shift ;;
    esac
done

[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

DOCKERHUB_USERNAME="${DOCKERHUB_USERNAME:-}"
BACKEND_IMAGE="${BACKEND_IMAGE:-${DOCKERHUB_USERNAME:+${DOCKERHUB_USERNAME}/ifritah-api}}"
FRONTEND_IMAGE="${FRONTEND_IMAGE:-${DOCKERHUB_USERNAME:+${DOCKERHUB_USERNAME}/ifritah-web}}"
DEV_TAG="${DEV_TAG:-dev}"
DEV_TENANT="$(tenant_full_name "${DEV_TENANT:-dev}")" || exit 1
TENANT_STATE_DIR="${TENANT_STATE_DIR:-/opt/tenant-state}"
export DEV_TAG
DIGEST_DIR="$(auto_pull_state_dir)"
if ! mkdir -p "$DIGEST_DIR"; then
    warn "Cannot create reconciliation state directory: $DIGEST_DIR"
    exit 1
fi

# Prevent concurrent runs. Keep the lock beside reconciliation state so
# read-only or restricted /tmp mounts cannot disable the poller.
LOCK_FILE="${AUTO_PULL_LOCK_FILE:-${DIGEST_DIR}/auto-pull.lock}"
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

if [ -z "$BACKEND_IMAGE" ] && [ -z "$FRONTEND_IMAGE" ]; then
    warn "DOCKERHUB_USERNAME not set in $CONFIG_FILE — nothing to do."
    exit 0
fi

# Skip silently if the dev tenant doesn't exist yet
if ! dokku apps:exists "${DEV_TENANT}-backend" 2>/dev/null; then
    exit 0
fi

# Per-tenant auto-redeploy switch. Operators can disable automatic redeploys
# for specific tenants/environments without turning off the cron by listing
# tenant names (comma/space separated) in AUTO_REDEPLOY_DISABLED in config.env.
# The names are matched after prefix normalization so either "dev" or
# "dev-dev" works. The dashboard's persistent TENANT_STATE_DIR setting is
# checked as well, so the per-tenant checkbox is enforced by this host-side
# poller rather than only being cosmetic UI state.
auto_redeploy_enabled() {
    local tenant="$1" raw item norm
    raw="${AUTO_REDEPLOY_DISABLED:-}"
    if [ -n "$raw" ]; then
        for item in ${raw//,/ }; do
            norm="$(tenant_full_name "$item" 2>/dev/null || echo "$item")"
            if [ "$norm" = "$tenant" ] || [ "$item" = "$tenant" ]; then
                return 1
            fi
        done
    fi

    local state_file="$TENANT_STATE_DIR/${tenant}.json"
    if [ -e "$state_file" ]; then
        if [ ! -r "$state_file" ]; then
            warn "Cannot read tenant auto-redeploy state: $state_file — skipping deploy"
            return 1
        fi
        if grep -Eq '"auto_redeploy"[[:space:]]*:[[:space:]]*false' "$state_file"; then
            info "Auto-redeploy disabled for $tenant (dashboard setting) — skipping."
            return 1
        fi
        if grep -Eq '"auto_redeploy"[[:space:]]*:' "$state_file" &&
            ! grep -Eq '"auto_redeploy"[[:space:]]*:[[:space:]]*true' "$state_file"; then
            warn "Invalid tenant auto-redeploy state: $state_file — skipping deploy"
            return 1
        fi
    fi
    return 0
}

# One polling cycle may discover new backend and frontend images together.
# Take one verified safety backup before the first deployment, then reuse it
# for the other paired image instead of creating two backups for one release.
AUTO_BACKUP_ATTEMPTED=0
AUTO_BACKUP_OK=0
ensure_auto_backup() {
    [ "${AUTO_BACKUP_BEFORE_REDEPLOY:-1}" = "0" ] && return 0
    if [ "$AUTO_BACKUP_ATTEMPTED" -eq 1 ]; then
        [ "$AUTO_BACKUP_OK" -eq 1 ]
        return
    fi
    AUTO_BACKUP_ATTEMPTED=1
    info "Creating verified pre-deploy backup for $DEV_TENANT ..."
    if bash "$SCRIPT_DIR/backup-tenant.sh" "$DEV_TENANT" \
            --origin auto --owner auto-redeploy --require-verified --no-prune \
            --config "$CONFIG_FILE"; then
        AUTO_BACKUP_OK=1
        return 0
    fi
    warn "Pre-deploy backup failed verification — skipping this poll's deploys."
    return 1
}

check_and_deploy() {
    local image="$1" app_type="$2"
    [ -z "$image" ] && return 0

    if ! auto_redeploy_enabled "$DEV_TENANT"; then
        info "Auto-redeploy disabled for $DEV_TENANT (AUTO_REDEPLOY_DISABLED) — skipping ${app_type}."
        return 0
    fi

    local full_image="${image}:${DEV_TAG}"
    local current_digest=""
    current_digest="$(auto_pull_digest_read_for_tenant "$app_type" "$DEV_TAG" "$DEV_TENANT" "$DIGEST_DIR" || true)"

    local remote_digest
    if ! remote_digest=$(get_remote_digest "$image" "$DEV_TAG"); then
        warn "Cannot resolve Docker Hub digest for $full_image; deployment was not attempted."
        return 1
    fi
    [ -n "$remote_digest" ] || {
        warn "Docker Hub returned an empty digest for $full_image; deployment was not attempted."
        return 1
    }
    [ "$current_digest" = "$remote_digest" ] && return 0

    log "New ${app_type} image: $full_image"
    info "  ${current_digest:-<first run>} → $remote_digest"

    # Safety gate: an automatic deploy must be preceded by a verified backup.
    # If it cannot be produced, retry on the next poll instead.
    ensure_auto_backup || return 0

    if bash "$SCRIPT_DIR/deploy-all.sh" "$full_image" \
            --type "$app_type" \
            --tenant "$DEV_TENANT" \
            --skip-canary; then
        if ! auto_pull_digest_write_for_tenant "$app_type" "$DEV_TAG" "$DEV_TENANT" \
                "$remote_digest" "$image" "$DIGEST_DIR"; then
            warn "Deploy succeeded but digest state could not be persisted for ${full_image}; it will retry."
            return 1
        fi
        log "Dev ${app_type} deployed ✓"
        return 0
    else
        warn "Deploy failed for ${app_type} — will retry next poll"
        return 1
    fi
}

RESULT=0
if [ "$CHECK_TYPE" = "both" ] || [ "$CHECK_TYPE" = "backend" ]; then
    check_and_deploy "$BACKEND_IMAGE" "backend" || RESULT=1
fi
if [ "$CHECK_TYPE" = "both" ] || [ "$CHECK_TYPE" = "frontend" ]; then
    check_and_deploy "$FRONTEND_IMAGE" "frontend" || RESULT=1
fi
exit "$RESULT"
