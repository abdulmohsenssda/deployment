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

# Prevent concurrent runs
LOCK_FILE="/tmp/auto-pull.lock"
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

DOCKERHUB_USERNAME="${DOCKERHUB_USERNAME:-}"
BACKEND_IMAGE="${BACKEND_IMAGE:-${DOCKERHUB_USERNAME:+${DOCKERHUB_USERNAME}/ifritah-api}}"
FRONTEND_IMAGE="${FRONTEND_IMAGE:-${DOCKERHUB_USERNAME:+${DOCKERHUB_USERNAME}/ifritah-web}}"
DEV_TAG="${DEV_TAG:-dev}"
DEV_TENANT="$(tenant_full_name "${DEV_TENANT:-dev}")" || exit 1
DIGEST_DIR="/var/lib/auto-pull"
mkdir -p "$DIGEST_DIR"

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
# "dev-dev" works. This is the allow-listed equivalent of the per-environment
# "disable auto-redeploy" checkbox surfaced in the dashboard.
auto_redeploy_enabled() {
    local tenant="$1" raw item norm
    raw="${AUTO_REDEPLOY_DISABLED:-}"
    [ -z "$raw" ] && return 0
    for item in ${raw//,/ }; do
        norm="$(tenant_full_name "$item" 2>/dev/null || echo "$item")"
        if [ "$norm" = "$tenant" ] || [ "$item" = "$tenant" ]; then
            return 1
        fi
    done
    return 0
}

check_and_deploy() {
    local image="$1" app_type="$2"
    [ -z "$image" ] && return 0

    if ! auto_redeploy_enabled "$DEV_TENANT"; then
        info "Auto-redeploy disabled for $DEV_TENANT (AUTO_REDEPLOY_DISABLED) — skipping ${app_type}."
        return 0
    fi

    local full_image="${image}:${DEV_TAG}"
    local digest_file="${DIGEST_DIR}/${app_type}-${DEV_TAG}.digest"
    local current_digest=""
    [ -f "$digest_file" ] && current_digest=$(cat "$digest_file")

    local remote_digest
    remote_digest=$(get_remote_digest "$image" "$DEV_TAG" 2>/dev/null || echo "")
    [ -z "$remote_digest" ] && { warn "Cannot fetch digest for $full_image"; return 0; }
    [ "$current_digest" = "$remote_digest" ] && return 0

    log "New ${app_type} image: $full_image"
    info "  ${current_digest:-<first run>} → $remote_digest"

    # Safety gate: an automatic deploy must be preceded by a verified backup of
    # the tenant's SQL + files. If the backup can't be produced/verified we skip
    # the deploy and retry next cycle rather than risk an unrecoverable rollout.
    # AUTO_BACKUP_BEFORE_REDEPLOY=0 opts out (not recommended).
    if [ "${AUTO_BACKUP_BEFORE_REDEPLOY:-1}" != "0" ]; then
        info "Creating verified pre-deploy backup for $DEV_TENANT ..."
        if ! bash "$SCRIPT_DIR/backup-tenant.sh" "$DEV_TENANT" \
                --origin auto --owner auto-redeploy --require-verified --no-prune \
                --config "$CONFIG_FILE"; then
            warn "Pre-deploy backup failed verification — skipping ${app_type} deploy this cycle."
            return 0
        fi
    fi

    if bash "$SCRIPT_DIR/deploy-all.sh" "$full_image" \
            --type "$app_type" \
            --tenant "$DEV_TENANT" \
            --skip-canary; then
        echo "$remote_digest" > "$digest_file"
        log "Dev ${app_type} deployed ✓"
    else
        warn "Deploy failed for ${app_type} — will retry next poll"
    fi
}

if [ "$CHECK_TYPE" = "both" ] || [ "$CHECK_TYPE" = "backend" ]; then
    check_and_deploy "$BACKEND_IMAGE" "backend"
fi
if [ "$CHECK_TYPE" = "both" ] || [ "$CHECK_TYPE" = "frontend" ]; then
    check_and_deploy "$FRONTEND_IMAGE" "frontend"
fi
