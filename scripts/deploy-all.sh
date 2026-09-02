#!/usr/bin/env bash
# =============================================================================
# deploy-all.sh — Deploy a Docker image to all tenants (canary-first)
# =============================================================================
# Usage:
#   ./scripts/deploy-all.sh <image> [--type backend|frontend] [--skip-canary]
#   ./scripts/deploy-all.sh <image> --tenant acme                  # single tenant
#   ./scripts/deploy-all.sh <image> --tenant acme --tenant bigcorp # multiple tenants
#   ./scripts/deploy-all.sh <image> --config /opt/deployment/config.dev.env
#
# Examples:
#   ./scripts/deploy-all.sh myuser/ifritah-api:v2.1                    # backend to all
#   ./scripts/deploy-all.sh myuser/ifritah-api:v2.1 --type backend
#   ./scripts/deploy-all.sh myuser/ifritah-web:v2.1 --type frontend
#   ./scripts/deploy-all.sh myuser/ifritah-api:v2.1 --tenant acme      # single tenant only
#   ./scripts/deploy-all.sh myuser/ifritah-api:v2.1 --skip-canary      # no canary check
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

IMAGE=""
APP_TYPE="backend"
SKIP_CANARY=false
declare -a TARGET_TENANTS=()
declare -a EXCLUDE_TENANTS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --type)            APP_TYPE="$2"; shift 2 ;;
        --skip-canary)     SKIP_CANARY=true; shift ;;
        --tenant)          TARGET_TENANTS+=("$2"); shift 2 ;;
        --exclude-tenant)  EXCLUDE_TENANTS+=("$2"); shift 2 ;;
        --config)          CONFIG_FILE="$2"; shift 2 ;;
        -*)                error "Unknown option: $1"; exit 1 ;;
        *)                 [ -z "$IMAGE" ] && IMAGE="$1"; shift ;;
    esac
done

[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

if [ -z "$IMAGE" ]; then
    echo "Usage: $0 <image> [--type backend|frontend] [--tenant <name>] [--skip-canary]"
    exit 1
fi

SUFFIX="-${APP_TYPE}"
BASE_DOMAIN="${BASE_DOMAIN:-app.example.com}"
public_protocol >/dev/null || exit 1
MYSQL_MASTER_DB="${MYSQL_MASTER_DB:-zatca_master}"
MIGRATE_CMD="${MIGRATE_CMD:-}"
IMAGE_PULL_POLICY="${IMAGE_PULL_POLICY:-always}"

ensure_deploy_image_available() {
    local image="$1"
    case "$IMAGE_PULL_POLICY" in
        always)
            log "Pulling image: $image"
            docker pull "$image" >/dev/null
            ;;
        missing)
            if docker image inspect "$image" >/dev/null 2>&1; then
                return 0
            fi
            log "Pulling image: $image"
            docker pull "$image" >/dev/null
            ;;
        never)
            if ! docker image inspect "$image" >/dev/null 2>&1; then
                error "Image is not present locally and IMAGE_PULL_POLICY=never: $image"
                exit 1
            fi
            ;;
        *)
            error "IMAGE_PULL_POLICY must be 'always', 'missing', or 'never' (got: $IMAGE_PULL_POLICY)"
            exit 1
            ;;
    esac
}

image_tag() {
    local image="$1"
    local tail="${image##*/}"
    if [[ "$tail" == *:* ]]; then
        printf '%s' "${tail##*:}"
    fi
}

# Returns the per-tenant image override (or empty string if none)
get_tenant_override() {
    local tenant="$1"
    local col="${APP_TYPE}_image"
    ! mysql_admin_configured && { echo ""; return; }
    run_mysql -N -B "$MYSQL_MASTER_DB" -e \
        "SELECT $col FROM tenant WHERE name='${tenant}' AND enabled=1 LIMIT 1;" 2>/dev/null \
        | head -1 || echo ""
}

# Deploy one app, honoring per-tenant override and running migrations
deploy_one() {
    local app="$1"
    local tenant="${app%${SUFFIX}}"
    local image="$IMAGE"

    # Per-tenant override (only for backend; frontend rarely needs pinning)
    local override
    override=$(get_tenant_override "$tenant")
    if [ -n "$override" ] && [ "$override" != "$IMAGE" ]; then
        warn "${tenant}: pinned to '${override}' — skipping global deploy"
        return 0
    fi

    if ! dokku config:set --no-restart "$app" \
            APP_IMAGE_VERSION="$(image_tag "$image")" \
            APP_IMAGE_REF="$image"; then
        return 1
    fi

    if ! dokku_git_from_image "$app" "$image"; then
        return 1
    fi

    # Run DB migration if configured (backend only)
    if [ "$APP_TYPE" = "backend" ] && [ -n "$MIGRATE_CMD" ]; then
        log "  Running migration on ${app}: ${MIGRATE_CMD}"
        dokku run "$app" $MIGRATE_CMD || warn "  Migration failed on ${app}"
    fi
    return 0
}

# Get matching apps — either specific tenants or all
if [ ${#TARGET_TENANTS[@]} -gt 0 ]; then
    # Deploy to specific tenants only
    APPS=""
    for t in "${TARGET_TENANTS[@]}"; do
        t="$(tenant_full_name "$t")" || exit 1
        APP_NAME="${t}${SUFFIX}"
        if dokku apps:exists "$APP_NAME" 2>/dev/null; then
            APPS="${APPS:+$APPS
}$APP_NAME"
        else
            error "App '$APP_NAME' not found. Tenant '$t' may not exist."
            exit 1
        fi
    done
else
    # Deploy to all tenants
    APPS=$(dokku apps:list 2>/dev/null | tail -n +2 | grep -- "${SUFFIX}$" || true)

    if [ -n "$(tenant_name_prefix)" ]; then
        APPS=$(while IFS= read -r app; do
            tenant="${app%${SUFFIX}}"
            tenant_in_scope "$tenant" && printf '%s\n' "$app"
        done <<< "$APPS")
    fi

    # Apply exclusions
    for ex in "${EXCLUDE_TENANTS[@]+"${EXCLUDE_TENANTS[@]}"}"; do
        ex="$(tenant_full_name "$ex")" || exit 1
        APPS=$(echo "$APPS" | grep -v -x "${ex}${SUFFIX}" || true)
    done
fi

if [ -z "$APPS" ]; then
    error "No ${APP_TYPE} apps found."
    exit 1
fi

APP_COUNT=$(echo "$APPS" | wc -l)

# Repair persisted tenant routing before pulling or deploying the image.
# A failed pull/rebuild must not prevent an existing tenant from moving to the
# configured BASE_DOMAIN.
while IFS= read -r app; do
    tenant="${app%${SUFFIX}}"
    frontend_app="${tenant}-frontend"
    if dokku apps:exists "$frontend_app" 2>/dev/null; then
        log "Synchronizing tenant routing: ${tenant}.${BASE_DOMAIN}"
        reconcile_tenant_routing "$tenant"
    else
        warn "${tenant}: frontend app not found; skipping routing reconciliation"
    fi
done <<< "$APPS"

ensure_deploy_image_available "$IMAGE"

log "Deploying ${IMAGE} to ${APP_COUNT} ${APP_TYPE} app(s)"
echo ""

# ---- Canary deploy ----
FIRST=$(echo "$APPS" | head -1)
REST=$(echo "$APPS" | tail -n +2)

log "=== Canary: ${FIRST} ==="
if ! deploy_one "$FIRST"; then
    error "Canary deploy failed — aborting."
    exit 1
fi

if ! $SKIP_CANARY && [ -n "$REST" ]; then
    TENANT="${FIRST%-${APP_TYPE}}"
    HEALTH_URL="$(public_tenant_url "$TENANT")"
    if [ "$APP_TYPE" = "backend" ]; then
        HEALTH_URL="${HEALTH_URL}/api/health"
    fi

    # Wait for container to be ready
    sleep 5

    log "Health check: ${HEALTH_URL}"
    if curl -sf --max-time 10 "$HEALTH_URL" > /dev/null 2>&1; then
        log "Canary healthy ✓"
    else
        warn "Health check failed (may not have /api/health endpoint — continuing)"
    fi

    echo ""
    info "Canary deployed to ${FIRST}. Proceeding to remaining apps..."
    echo ""
fi

# ---- Deploy to remaining apps ----
if [ -n "$REST" ]; then
    FAILED=0
    while IFS= read -r app; do
        log "=== Deploying: ${app} ==="
        if deploy_one "$app"; then
            log "${app} ✓"
        else
            error "${app} FAILED"
            FAILED=$((FAILED + 1))
        fi
    done <<< "$REST"

    echo ""
    if [ $FAILED -eq 0 ]; then
        log "All ${APP_COUNT} ${APP_TYPE} apps deployed successfully."
    else
        error "${FAILED} app(s) failed to deploy."
        exit 1
    fi
else
    echo ""
    log "Deployment complete (1 app)."
fi
