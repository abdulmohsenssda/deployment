#!/usr/bin/env bash
# =============================================================================
# update-tenant.sh — Update a tenant's app images, config, or routing
# =============================================================================
# Usage:
#   ./scripts/update-tenant.sh <tenant-name> [options]
#
# Options:
#   --backend-image <image>    Deploy new backend image
#   --frontend-image <image>   Deploy new frontend image
#   --env KEY=VALUE            Set/update env var (repeatable)
#   --restart                  Restart all tenant containers
#   --scale <n>                Scale backend to n instances
#   --skip-drift-check         Deploy even if backend + frontend image
#                              versions (org.opencontainers.image.version)
#                              disagree. Use only when knowingly running a
#                              mismatched pair (e.g. targeted rollback).
#   --skip-migrations          Skip the idempotent schema/migration replay
#                              that normally follows a --backend-image update.
#                              Only use this for rollbacks to older backend
#                              images (schema can only move forward).
#   --config <path>            Path to config.env file (default: ../config.env)
#
# Routing behavior:
#   Every update reconciles the persisted frontend domain, APP_DOMAIN, and
#   API_URL with the current BASE_DOMAIN. This repairs tenants created before
#   a base-domain change; use post-merge-cleanup.sh for a fleet-wide repair.
#
# Migration behavior:
#   When --backend-image is provided, this script re-applies every
#   pkg/db/migrations/*.sql file bundled inside the new backend image to the
#   tenant's DB. The migrations are already idempotent (each ALTER is guarded
#   by information_schema lookups), and applying them BEFORE the container is
#   swapped means the new binary never boots against a schema it cannot INSERT
#   into. This closes the class of failure where a tenant DB was frozen at an
#   older schema (init-tenant-db.sh only ran at provisioning time) while the
#   backend image advanced through new migrations — the failure mode was a
#   silent HTTP 400 with an empty body from ``purchase_bill.go`` line 173
#   after the ``INSERT INTO purchase_bill_product`` failed with
#   ``Error 1054 Unknown column 'cost_price'``.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib.sh"

# Parse --config early
CONFIG_FILE="$PROJECT_DIR/config.env"
for i in $(seq 1 $#); do
    if [ "${!i}" = "--config" ]; then
        j=$((i+1))
        CONFIG_FILE="${!j}"
        break
    fi
done

[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
IMAGE_PULL_POLICY="${TENANT_IMAGE_PULL_POLICY:-${IMAGE_PULL_POLICY:-always}}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
log()   { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; }

TENANT_NAME=""
BACKEND_IMAGE=""
FRONTEND_IMAGE=""
RESTART=false
SCALE=""
SKIP_DRIFT_CHECK=false
SKIP_MIGRATIONS=false
declare -a ENV_VARS=()

ensure_update_image_available() {
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

# Read the org.opencontainers.image.version label from an image ref.
# Empty string on failure (missing label, missing image, docker error).
# Callers must have already pulled the image via ensure_update_image_available.
image_version_label() {
    local image="$1"
    docker inspect --format='{{index .Config.Labels "org.opencontainers.image.version"}}' "$image" 2>/dev/null | tr -d '\r\n' || true
}

# Refuse to deploy a backend + frontend pair whose image versions disagree.
# The pair is only compared when both sides are being updated in the same
# invocation — pinning just one image is still allowed.
#
# Bypass with --skip-drift-check when knowingly running mismatched images
# (rare; usually only needed during a rollback investigation).
assert_image_versions_match() {
    if [ -z "$BACKEND_IMAGE" ] || [ -z "$FRONTEND_IMAGE" ]; then
        return 0
    fi
    if [ "$SKIP_DRIFT_CHECK" = "true" ]; then
        warn "Skipping backend/frontend image-version drift check (--skip-drift-check)"
        return 0
    fi

    local backend_ver frontend_ver
    backend_ver="$(image_version_label "$BACKEND_IMAGE")"
    frontend_ver="$(image_version_label "$FRONTEND_IMAGE")"

    # If either image doesn't carry a version label, warn and continue —
    # this covers older images built before the label was added, or ad-hoc
    # locally-built images used during development.
    if [ -z "$backend_ver" ] || [ -z "$frontend_ver" ]; then
        warn "One or both images have no org.opencontainers.image.version label:"
        warn "  backend  ${BACKEND_IMAGE}  version='${backend_ver:-<none>}'"
        warn "  frontend ${FRONTEND_IMAGE} version='${frontend_ver:-<none>}'"
        warn "Cannot confirm drift-free pair. Continuing anyway; pass --skip-drift-check"
        warn "to silence this warning permanently."
        return 0
    fi

    if [ "$backend_ver" != "$frontend_ver" ]; then
        error "Refusing to deploy: backend/frontend version drift detected."
        error "  backend  ${BACKEND_IMAGE}  version=${backend_ver}"
        error "  frontend ${FRONTEND_IMAGE} version=${frontend_ver}"
        error ""
        error "Rebuild both apps from a commit that shares the same VERSION file,"
        error "or override with --skip-drift-check if you know what you're doing"
        error "(e.g. a rollback investigation against a known-good backend and a"
        error "specific frontend build)."
        exit 1
    fi

    log "Image versions match: ${backend_ver} (backend + frontend)"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backend-image)     BACKEND_IMAGE="$2"; shift 2 ;;
        --frontend-image)    FRONTEND_IMAGE="$2"; shift 2 ;;
        --env)               ENV_VARS+=("$2"); shift 2 ;;
        --restart)           RESTART=true; shift ;;
        --scale)             SCALE="$2"; shift 2 ;;
        --skip-drift-check)  SKIP_DRIFT_CHECK=true; shift ;;
        --skip-migrations)   SKIP_MIGRATIONS=true; shift ;;
        --config)            shift 2 ;;  # already parsed above
        -*)                  error "Unknown option: $1"; exit 1 ;;
        *)                   [ -z "$TENANT_NAME" ] && TENANT_NAME="$1"; shift ;;
    esac
done

if [ -z "$TENANT_NAME" ]; then
    echo "Usage: $0 <tenant-name> [options]"
    exit 1
fi

TENANT_NAME="$(tenant_full_name "$TENANT_NAME")" || exit 1

BASE_DOMAIN="${BASE_DOMAIN:?BASE_DOMAIN not set in config.env}"
TENANT_DOMAIN="${TENANT_NAME}.${BASE_DOMAIN}"
PUBLIC_TENANT_URL="$(public_tenant_url "$TENANT_NAME")" || exit 1

BACKEND_APP="${TENANT_NAME}-backend"
FRONTEND_APP="${TENANT_NAME}-frontend"

# ---- Set env vars ----
for ev in "${ENV_VARS[@]+"${ENV_VARS[@]}"}"; do
    if [[ "$ev" == *"="* ]]; then
        log "Setting env: $ev"
        dokku config:set --no-restart "$BACKEND_APP" "$ev"
    fi
done

# ---- Deploy new images ----
# Pull each image first so image_version_label can inspect the manifest, then
# run the drift preflight before any dokku config:set actually mutates state.
if [ -n "$BACKEND_IMAGE" ]; then
    ensure_update_image_available "$BACKEND_IMAGE"
fi
if [ -n "$FRONTEND_IMAGE" ]; then
    ensure_update_image_available "$FRONTEND_IMAGE"
fi

assert_image_versions_match

# ---- Apply schema/migrations from the new backend image ----
# The tenant's DB was initialised via init-tenant-db.sh at provisioning time
# and has been frozen at that schema ever since. If the backend image has
# advanced through new migrations (e.g. columns added to purchase_bill_product
# in ifritah-go#53), the running container will fail every INSERT that
# references the new columns and return an empty-body 400 (see
# pkg/handlers/purchase_bill.go finalizePurchaseBill line ~173). Every
# migration in pkg/db/migrations/*.sql is idempotent (information_schema
# guards on ALTERs), so re-applying the full set is a no-op where the DB is
# already current, and a fix-up where it is not.
if [ -n "$BACKEND_IMAGE" ] && [ "$SKIP_MIGRATIONS" != "true" ]; then
    log "Applying schema/migrations from ${BACKEND_IMAGE} (idempotent)"
    if ! "$SCRIPT_DIR/init-tenant-db.sh" "$TENANT_NAME" \
        --schema-only \
        --backend-image "$BACKEND_IMAGE" \
        --config "$CONFIG_FILE"; then
        error "Migration replay failed; refusing to swap the container onto a"
        error "possibly-incompatible schema. Fix the DB (or pass --skip-migrations"
        error "if you know the schema is already correct for the target image)"
        error "and re-run update-tenant.sh."
        exit 1
    fi
fi

if [ -n "$BACKEND_IMAGE" ]; then
    log "Deploying backend: $BACKEND_IMAGE"
    dokku config:set --no-restart "$BACKEND_APP" \
        APP_IMAGE_VERSION="$(image_tag "$BACKEND_IMAGE")" \
        APP_IMAGE_REF="$BACKEND_IMAGE"
    dokku_git_from_image "$BACKEND_APP" "$BACKEND_IMAGE"
fi

if [ -n "$FRONTEND_IMAGE" ]; then
    log "Deploying frontend: $FRONTEND_IMAGE"
    dokku config:set --no-restart "$FRONTEND_APP" \
        APP_IMAGE_VERSION="$(image_tag "$FRONTEND_IMAGE")" \
        APP_IMAGE_REF="$FRONTEND_IMAGE"
    dokku_git_from_image "$FRONTEND_APP" "$FRONTEND_IMAGE"
fi

# Existing tenants keep APP_DOMAIN/API_URL in Dokku config from their original
# provisioning. Reconcile those persisted values whenever the tenant is updated.
# The backend must remain internal-only; the frontend owns the public hostname.
log "Synchronizing tenant routing: ${PUBLIC_TENANT_URL}"
dokku domains:clear "$BACKEND_APP" >/dev/null || true
dokku proxy:disable "$BACKEND_APP" >/dev/null 2>&1 || true
dokku domains:clear "$FRONTEND_APP" >/dev/null
dokku domains:add "$FRONTEND_APP" "$TENANT_DOMAIN" >/dev/null
dokku config:set --no-restart "$FRONTEND_APP" \
    APP_DOMAIN="$TENANT_DOMAIN" \
    API_URL="${PUBLIC_TENANT_URL}/api"

# ---- Scale ----
if [ -n "$SCALE" ]; then
    log "Scaling backend to $SCALE instances"
    dokku ps:scale "$BACKEND_APP" web="$SCALE"
fi

# ---- Restart ----
if $RESTART; then
    log "Restarting tenant..."
    dokku ps:restart "$BACKEND_APP"
    dokku ps:restart "$FRONTEND_APP"
else
    # APP_DOMAIN/API_URL are runtime config, so apply them even when no
    # image update or explicit --restart was requested.
    dokku ps:restart "$FRONTEND_APP"
fi

log "Done. Check status: dokku ps:report $BACKEND_APP"
