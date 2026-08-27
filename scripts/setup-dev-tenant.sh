#!/usr/bin/env bash
# =============================================================================
# setup-dev-tenant.sh — Provision the single dev tenant
# =============================================================================
# Creates exactly one dev tenant whose backend (and optionally frontend) tracks
# DEV_TAG. App repo CI should build the VERSION tag; webhook deploys are preferred.
#
# Idempotent: re-running just refreshes the image pins.
#
# Usage:
#   bash scripts/setup-dev-tenant.sh                 # use config.env defaults
#   bash scripts/setup-dev-tenant.sh --name dev      # override tenant name
#   bash scripts/setup-dev-tenant.sh --tag v1.2.3    # override dev tag
#   bash scripts/setup-dev-tenant.sh --frontend      # also pin frontend to DEV_TAG
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()   { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; }
info()  { echo -e "${BLUE}[i]${NC} $*"; }

CONFIG_FILE="${CONFIG_FILE:-$PROJECT_DIR/config.env}"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
BASE_DOMAIN="${BASE_DOMAIN:-app.example.com}"

NAME="${DEV_TENANT:-dev}"
TAG="${DEV_TAG:-dev}"
PIN_FRONTEND=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)     NAME="$2"; shift 2 ;;
        --tag)      TAG="$2"; shift 2 ;;
        --frontend) PIN_FRONTEND=true; shift ;;
        --config)   CONFIG_FILE="$2"; shift 2 ;;
        -h|--help)  sed -n '1,20p' "$0"; exit 0 ;;
        *)          error "Unknown option: $1"; exit 1 ;;
    esac
done

NAME="$(tenant_full_name "$NAME")" || exit 1

DOCKERHUB_USERNAME="${DOCKERHUB_USERNAME:-}"
if [ -z "$DOCKERHUB_USERNAME" ]; then
    error "DOCKERHUB_USERNAME not set in $CONFIG_FILE"
    exit 1
fi

BACKEND_IMG="${BACKEND_IMAGE:-${DOCKERHUB_USERNAME}/ifritah-api}:${TAG}"
FRONTEND_IMG="${FRONTEND_IMAGE:-${DOCKERHUB_USERNAME}/ifritah-web}:${TAG}"

log "Dev tenant setup"
info "  Name:           ${NAME}"
info "  Backend image:  ${BACKEND_IMG}"
$PIN_FRONTEND && info "  Frontend image: ${FRONTEND_IMG}"

# 1) Create the tenant if it doesn't already exist
APP_BACKEND="${NAME}-backend"
if dokku apps:exists "$APP_BACKEND" 2>/dev/null; then
    info "Tenant '${NAME}' already exists — refreshing image pin only."
else
    log "Creating tenant '${NAME}' (git-only, will be deployed by auto-pull)..."
    bash "$SCRIPT_DIR/create-tenant.sh" "$NAME" --git-only --config "$CONFIG_FILE"
fi

# 2) Pin backend to DEV_TAG in the master DB so global deploys skip it
log "Pinning ${NAME} backend → ${BACKEND_IMG}"
bash "$SCRIPT_DIR/set-tenant-image.sh" "$NAME" --backend "$BACKEND_IMG" --config "$CONFIG_FILE"

if $PIN_FRONTEND; then
    log "Pinning ${NAME} frontend → ${FRONTEND_IMG}"
    bash "$SCRIPT_DIR/set-tenant-image.sh" "$NAME" --frontend "$FRONTEND_IMG" --config "$CONFIG_FILE"
fi

# 3) Trigger an initial pull+deploy if the DEV_TAG image already exists on Docker Hub
log "Triggering initial deploy from ${BACKEND_IMG}..."
if bash "$SCRIPT_DIR/deploy-all.sh" "$BACKEND_IMG" --type backend --tenant "$NAME" --skip-canary; then
    log "Initial backend deploy ✓"
else
    warn "Initial deploy failed (image may not exist yet). Push to your dev branch — auto-pull will pick it up."
fi

if $PIN_FRONTEND; then
    if bash "$SCRIPT_DIR/deploy-all.sh" "$FRONTEND_IMG" --type frontend --tenant "$NAME" --skip-canary; then
        log "Initial frontend deploy ✓"
    else
        warn "Initial frontend deploy failed — auto-pull will retry."
    fi
fi

echo ""
log "Dev tenant ready."
info "URL:           $(public_tenant_url "$NAME")"
info "Auto-deploy:   pushes to the 'dev' branch → CI builds ${BACKEND_IMG} → auto-pull.sh deploys here every 2 min"
info "Manual deploy: bash scripts/deploy-all.sh ${BACKEND_IMG} --tenant ${NAME}"
info "Logs:          bash scripts/tail-logs.sh ${APP_BACKEND}"
