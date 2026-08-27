#!/usr/bin/env bash
# =============================================================================
# rollback-tenant.sh — Rollback a tenant's backend or frontend to a previous image
# =============================================================================
# Usage:
#   ./scripts/rollback-tenant.sh <tenant-name> [options]
#
# Options:
#   --type <backend|frontend>  Which app to rollback (default: backend)
#   --to <image:tag>           Specific image to rollback to
#   --list                     Show recent deploy history (available tags)
#   --config <path>            Path to config.env file (default: ../config.env)
#
# Examples:
#   ./scripts/rollback-tenant.sh acme --list
#   ./scripts/rollback-tenant.sh acme --to myuser/ifritah-api:abc1234
#   ./scripts/rollback-tenant.sh acme --type frontend --to myuser/ifritah-web:prev
#   ./scripts/rollback-tenant.sh --all --to myuser/ifritah-api:abc1234
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

CONFIG_FILE="$PROJECT_DIR/config.env"
TENANT_NAME=""
APP_TYPE="backend"
ROLLBACK_IMAGE=""
LIST_MODE=false
ALL_TENANTS=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --type)    APP_TYPE="$2"; shift 2 ;;
        --to)      ROLLBACK_IMAGE="$2"; shift 2 ;;
        --list)    LIST_MODE=true; shift ;;
        --all)     ALL_TENANTS=true; shift ;;
        --config)  CONFIG_FILE="$2"; shift 2 ;;
        -*)        error "Unknown option: $1"; exit 1 ;;
        *)         [ -z "$TENANT_NAME" ] && TENANT_NAME="$1"; shift ;;
    esac
done

[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

if [ -z "$TENANT_NAME" ] && ! $ALL_TENANTS; then
    echo "Usage: $0 <tenant-name> [--type backend|frontend] [--to <image:tag>] [--list]"
    echo "       $0 --all --to <image:tag> [--type backend|frontend]"
    exit 1
fi

if [ -n "$TENANT_NAME" ]; then
    TENANT_NAME="$(tenant_full_name "$TENANT_NAME")" || exit 1
fi

APP_SUFFIX="-${APP_TYPE}"

# ---- List mode: show deploy history ----
if $LIST_MODE; then
    APP_NAME="${TENANT_NAME}${APP_SUFFIX}"
    if ! dokku apps:exists "$APP_NAME" 2>/dev/null; then
        error "App '$APP_NAME' not found."
        exit 1
    fi

    echo ""
    info "=== Deploy history for $APP_NAME ==="
    echo ""

    # Show current image
    CURRENT_IMAGE=$(dokku git:report "$APP_NAME" 2>/dev/null | grep "source-image" | awk '{print $NF}' || echo "unknown")
    info "  Current image: $CURRENT_IMAGE"
    echo ""

    # Show recent git/deploy log
    info "  Recent deploys:"
    dokku events:list 2>/dev/null | grep "$APP_NAME" | head -10 || \
        warn "  No event log available. Current image: $CURRENT_IMAGE"

    echo ""
    info "To rollback, run:"
    info "  $0 $TENANT_NAME --to <image:tag>"
    exit 0
fi

# ---- Validate rollback image ----
if [ -z "$ROLLBACK_IMAGE" ]; then
    error "No rollback target specified. Use --to <image:tag> or --list to see history."
    exit 1
fi

# ---- Rollback single tenant ----
rollback_app() {
    local app="$1"
    local image="$2"

    if ! dokku apps:exists "$app" 2>/dev/null; then
        error "App '$app' not found."
        return 1
    fi

    # Get current image for logging
    local current_image
    current_image=$(dokku git:report "$app" 2>/dev/null | grep "source-image" | awk '{print $NF}' || echo "unknown")

    log "Rolling back $app"
    info "  From: $current_image"
    info "  To:   $image"

    if dokku_git_from_image "$app" "$image"; then
        log "$app rolled back successfully ✓"
    else
        error "$app rollback FAILED"
        return 1
    fi
}

if $ALL_TENANTS; then
    # Rollback all tenants of this type
    APPS=$(dokku apps:list 2>/dev/null | tail -n +2 | grep -- "${APP_SUFFIX}$" || true)
    if [ -n "$(tenant_name_prefix)" ]; then
        APPS=$(while IFS= read -r app; do
            tenant="${app%${APP_SUFFIX}}"
            tenant_in_scope "$tenant" && printf '%s\n' "$app"
        done <<< "$APPS")
    fi

    if [ -z "$APPS" ]; then
        error "No ${APP_TYPE} apps found."
        exit 1
    fi

    APP_COUNT=$(echo "$APPS" | wc -l)
    log "Rolling back ${APP_COUNT} ${APP_TYPE} app(s) to: $ROLLBACK_IMAGE"
    echo ""

    FAILED=0
    while IFS= read -r app; do
        if ! rollback_app "$app" "$ROLLBACK_IMAGE"; then
            FAILED=$((FAILED + 1))
        fi
    done <<< "$APPS"

    echo ""
    if [ $FAILED -eq 0 ]; then
        log "All ${APP_COUNT} app(s) rolled back."
    else
        error "${FAILED} app(s) failed to rollback."
        exit 1
    fi
else
    # Rollback single tenant
    APP_NAME="${TENANT_NAME}${APP_SUFFIX}"
    echo ""
    rollback_app "$APP_NAME" "$ROLLBACK_IMAGE"
    echo ""
fi
