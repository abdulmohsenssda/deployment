#!/usr/bin/env bash
# =============================================================================
# post-merge-cleanup.sh — apply PR #41 fixes to existing tenants on a host
# =============================================================================
# What it does (idempotent):
#   1. Removes any leftover broken /api nginx snippets in
#      /home/dokku/<frontend>/nginx.conf.d/api-proxy.conf inside the dokku
#      container. These reference <backend>-web:<port> which doesn't resolve
#      from Dokku's nginx context and break `nginx:validate-config`.
#   2. For every tenant pair (<name>-backend / <name>-frontend), attaches
#      both apps to one shared tenant docker network.
#   3. Removes the public domain/proxy from backend apps. Only frontend apps
#      should own <tenant>.$BASE_DOMAIN; otherwise Dokku generates duplicate
#      nginx server_name blocks.
#   4. Sets BACKEND_URL / PORT / APP_DOMAIN / API_URL on the frontend, BASEURL
#      on the backend, then `ps:rebuild`s both apps so the new wiring is applied.
#   5. Validates Dokku nginx config and rebuilds proxy config.
#
# Usage:
#   sudo bash scripts/post-merge-cleanup.sh                 # all tenants
#   sudo bash scripts/post-merge-cleanup.sh qa-7k4m foo     # specific tenants
#
# Env overrides: DOKKU_CONTAINER (default: dokku), BACKEND_PORT (8090),
#                TENANT_APP_NETWORK (web), FRONTEND_PORT (8000),
#                BASEURL (/api/v2), BASE_DOMAIN, DRY_RUN=1
# =============================================================================

set -euo pipefail

DOKKU_CONTAINER="${DOKKU_CONTAINER:-dokku}"
BACKEND_PORT="${BACKEND_PORT:-8090}"
FRONTEND_PORT="${FRONTEND_PORT:-8000}"
BASEURL="${BASEURL:-/api/v2}"
TENANT_NETWORK="${TENANT_APP_NETWORK:-web}"
DRY_RUN="${DRY_RUN:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib.sh"

# Try to source config.env for BASE_DOMAIN if not provided
if [ -z "${BASE_DOMAIN:-}" ] && [ -f "$PROJECT_DIR/config.env" ]; then
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/config.env"
fi
BASE_DOMAIN="${BASE_DOMAIN:?BASE_DOMAIN not set (in env or $PROJECT_DIR/config.env)}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
log()   { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[x]${NC} $*" >&2; }
info()  { echo -e "${BLUE}[i]${NC} $*"; }

LOG_DIR="${LOG_DIR:-${PROJECT_DIR}/logs}"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="${LOG_DIR}/post-merge-cleanup-$(date +%Y%m%d-%H%M%S).log"
if [ -w "$LOG_DIR" ]; then
    exec > >(tee -a "$LOG_FILE") 2>&1
    info "Logging to: $LOG_FILE"
fi

dk() {
    if [ "$DRY_RUN" = "1" ]; then
        echo "[dry-run] docker exec $DOKKU_CONTAINER $*"
        return 0
    fi
    docker exec "$DOKKU_CONTAINER" "$@"
}

dk_dokku() { dk dokku "$@"; }

validate_docker_network_name() {
    local network="$1"
    case "$network" in
        *[!A-Za-z0-9_.-]*)
            error "Invalid Docker network name: $network"
            exit 1
            ;;
    esac
}

find_existing_tenant_network() {
    dk bash -lc "docker network ls --format '{{.Name}}' | awk '\$1 == \"web\" || /^tenant-/ { print; exit }'"
}

ensure_tenant_network() {
    local network="$1"
    local create_error=""
    local fallback_network=""
    validate_docker_network_name "$network"
    TENANT_NETWORK="$network"

    if dk bash -lc "docker network inspect $network >/dev/null 2>&1"; then
        info "Network $network already exists"
        return 0
    fi

    log "Creating shared tenant docker network: $network"
    if ! dk_dokku network:create "$network"; then
        warn "dokku network:create did not create $network; verifying Docker network state."
    fi

    if dk bash -lc "docker network inspect $network >/dev/null 2>&1"; then
        info "Network $network is ready"
        return 0
    fi

    warn "Creating Docker network directly: $network"
    if dk bash -lc "docker network create $network >/dev/null"; then
        if ! dk bash -lc "docker network inspect $network >/dev/null 2>&1"; then
            error "Docker network was not created: $network"
            exit 1
        fi
        info "Network $network is ready"
        return 0
    fi

    create_error="$(dk bash -lc "docker network create $network" 2>&1 || true)"
    if [ -n "$create_error" ]; then
        warn "docker network create failed for $network: $create_error"
    fi

    fallback_network="$(find_existing_tenant_network 2>/dev/null || true)"
    if [ -n "$fallback_network" ]; then
        validate_docker_network_name "$fallback_network"
        if dk bash -lc "docker network inspect $fallback_network >/dev/null 2>&1"; then
            warn "Docker cannot allocate a new network; reusing existing tenant network: $fallback_network"
            TENANT_NETWORK="$fallback_network"
            return 0
        fi
    fi

    error "Failed to create Docker network: $network"
    exit 1
}

# Tenant list: from CLI args, else derive from `dokku apps:list`
declare -a TENANTS=()
if [ $# -gt 0 ]; then
    TENANTS=("$@")
else
    log "Discovering tenants from 'dokku apps:list'..."
    while IFS= read -r app; do
        case "$app" in
            *-frontend) TENANTS+=("${app%-frontend}") ;;
        esac
    done < <(dk_dokku apps:list 2>/dev/null | tail -n +2)
fi

if [ ${#TENANTS[@]} -eq 0 ]; then
    warn "No tenants found. Exiting."
    exit 0
fi

log "Tenants to process: ${TENANTS[*]}"
ensure_tenant_network "$TENANT_NETWORK"

# ---------------------------------------------------------------------------
# 1. Remove broken /api nginx snippets across every frontend app
# ---------------------------------------------------------------------------
log "Removing leftover api-proxy.conf snippets..."
for t in "${TENANTS[@]}"; do
    fe="${t}-frontend"
    snippet="/home/dokku/${fe}/nginx.conf.d/api-proxy.conf"
    if dk test -f "$snippet" 2>/dev/null; then
        info "  removing $snippet"
        dk rm -f "$snippet" || warn "  failed to remove $snippet"
    fi
done

# ---------------------------------------------------------------------------
# 2-3. Per-tenant: network, env, rebuild
# ---------------------------------------------------------------------------
for t in "${TENANTS[@]}"; do
    be="${t}-backend"; fe="${t}-frontend"
    net="$TENANT_NETWORK"
    domain="${t}.${BASE_DOMAIN}"
    public_url="$(public_tenant_url "$t")" || {
        error "  invalid public URL for tenant $t; skipping"
        continue
    }

    log "=== ${t} ==="

    # Skip if either app is missing
    if ! dk_dokku apps:exists "$be" >/dev/null 2>&1; then
        warn "  $be does not exist; skipping"
        continue
    fi
    if ! dk_dokku apps:exists "$fe" >/dev/null 2>&1; then
        warn "  $fe does not exist; skipping"
        continue
    fi

    info "  network: $net"
    # Use only attach-post-create: Dokku rejects setting both attach-post-create
    # and attach-post-deploy to the same network on the same app.
    dk_dokku network:set "$be" attach-post-create "$net" >/dev/null || true
    dk_dokku network:set "$fe" attach-post-create "$net" >/dev/null || true

    info "  domains: frontend owns $domain; backend is internal-only"
    dk_dokku domains:clear "$be" >/dev/null || true
    dk_dokku proxy:disable "$be" >/dev/null 2>&1 || true
    dk_dokku domains:clear "$fe" >/dev/null || true
    dk_dokku domains:add "$fe" "$domain" >/dev/null || true

    info "  config: backend BASEURL=$BASEURL"
    dk_dokku config:set --no-restart "$be" BASEURL="$BASEURL" >/dev/null

    info "  config: frontend BACKEND_URL=http://${be}.web:${BACKEND_PORT}"
    dk_dokku config:set --no-restart "$fe" \
        BACKEND_URL="http://${be}.web:${BACKEND_PORT}" \
        PORT="$FRONTEND_PORT" \
        APP_DOMAIN="$domain" \
        API_URL="${public_url}/api" >/dev/null

    info "  rebuild: $be, $fe"
    dk_dokku ps:rebuild "$be" || warn "  $be rebuild failed (deploy not yet done?)"
    dk_dokku ps:rebuild "$fe" || warn "  $fe rebuild failed (deploy not yet done?)"
done

# ---------------------------------------------------------------------------
# 4. Validate and rebuild Dokku nginx config
# ---------------------------------------------------------------------------
log "Validating Dokku nginx config..."
if ! dk_dokku nginx:validate-config; then
    error "nginx:validate-config failed — inspect output above"
fi

log "Rebuilding Dokku proxy config (all apps)..."
dk_dokku proxy:build-config --all >/dev/null || warn "proxy:build-config failed"

log "Done. Verify next:"
for t in "${TENANTS[@]}"; do
    if site_url="$(public_tenant_url "$t")"; then
        echo "  curl -I ${site_url}/"
    else
        echo "  (invalid public URL for ${t})"
    fi
done
