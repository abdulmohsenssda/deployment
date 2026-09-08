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
source "$SCRIPT_DIR/tenant-provenance.sh"

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
VERIFY_RETRIES="${TENANT_VERIFY_RETRIES:-15}"
VERIFY_DELAY="${TENANT_VERIFY_DELAY:-2}"
declare -A PREVIOUS_CONFIG=()

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

# Deploy one app, honoring per-tenant override and verifying BuildIdentity.
deploy_one() {
    local app="$1"
    local tenant="${app%${SUFFIX}}"
    local image="$IMAGE"
    local previous_image previous_identity backup_info="" backup_id="" backup_artifact=""
    local migrations_attempted=false

    # Per-tenant override (only for backend; frontend rarely needs pinning)
    local override
    override=$(get_tenant_override "$tenant")
    if [ -n "$override" ] && [ "$override" != "$IMAGE" ]; then
        warn "${tenant}: pinned to '${override}' — skipping global deploy"
        return 0
    fi

    previous_image="$(dokku git:report "$app" 2>/dev/null |
        awk -F': ' 'tolower($1) ~ /source-image/ {print $2; exit}' || true)"
    capture_runtime_config "$app"
    previous_identity="$(tenant_current_identity "$tenant" "$APP_TYPE" || true)"
    local resolved_ref="${image%@*}@${BUILD_DIGEST}"

    if [ "$APP_TYPE" = "backend" ]; then
        if ! backup_info="$(create_verified_tenant_db_backup "$tenant" "$CONFIG_FILE")"; then
            error "${tenant}: verified pre-migration database backup unavailable; refusing deployment"
            tenant_record_failure "$tenant" "$APP_TYPE" \
                "verified pre-migration database backup unavailable" 2>/dev/null || true
            return 1
        fi
        IFS=$'\t' read -r backup_id backup_artifact _ <<< "$backup_info"
        if [ -z "$backup_id" ] || [ -z "$backup_artifact" ]; then
            error "${tenant}: incomplete backup identity; refusing deployment"
            tenant_record_failure "$tenant" "$APP_TYPE" \
                "pre-migration backup identity incomplete" 2>/dev/null || true
            return 1
        fi
    fi

    if ! tenant_record_audit "$tenant" "$APP_TYPE" "$image" "$resolved_ref" "$BUILD_DIGEST" \
        "$BUILD_CHANNEL" "$BUILD_VERSION" "$BUILD_COMMIT" "$BUILD_COMMIT_SHORT" \
        "$BUILD_WORKFLOW_RUN_ID" "$BUILD_WORKFLOW_RUN_URL" "$BUILD_BUILT_AT" "$previous_image" \
        "$(printf '%s' "$previous_identity" | cut -f2)" "started" "" \
        "$backup_id" "$backup_artifact"; then
        error "${tenant}: deployment audit is unavailable; refusing an untracked swap"
        tenant_record_failure "$tenant" "$APP_TYPE" "deployment audit start failed" 2>/dev/null || true
        return 1
    fi

    if [ "$APP_TYPE" = "backend" ]; then
        migrations_attempted=true
        log "  Replaying schema/migrations on ${tenant} before image swap"
        if ! "$SCRIPT_DIR/init-tenant-db.sh" "$tenant" --schema-only \
            --backend-image "$image" --config "$CONFIG_FILE"; then
            error "  Migration failed on ${app}; refusing image swap. Restore backup ${backup_id} before retry."
            tenant_record_failure "$tenant" "$APP_TYPE" \
                "migration replay failed; restore pre-migration backup before retry" 2>/dev/null || true
            tenant_record_audit "$tenant" "$APP_TYPE" "$image" "$resolved_ref" "$BUILD_DIGEST" \
                "$BUILD_CHANNEL" "$BUILD_VERSION" "$BUILD_COMMIT" "$BUILD_COMMIT_SHORT" \
                "$BUILD_WORKFLOW_RUN_ID" "$BUILD_WORKFLOW_RUN_URL" "$BUILD_BUILT_AT" "$previous_image" \
                "$(printf '%s' "$previous_identity" | cut -f2)" "failed" \
                "migration replay failed; restore backup before retry" \
                "$backup_id" "$backup_artifact" 2>/dev/null || true
            return 1
        fi
        if [ -n "$MIGRATE_CMD" ] && ! dokku run "$app" $MIGRATE_CMD; then
            error "  Custom migration failed on ${app}; refusing image swap. Restore backup ${backup_id} before retry."
            tenant_record_failure "$tenant" "$APP_TYPE" \
                "custom migration failed; restore pre-migration backup before retry" 2>/dev/null || true
            tenant_record_audit "$tenant" "$APP_TYPE" "$image" "$resolved_ref" "$BUILD_DIGEST" \
                "$BUILD_CHANNEL" "$BUILD_VERSION" "$BUILD_COMMIT" "$BUILD_COMMIT_SHORT" \
                "$BUILD_WORKFLOW_RUN_ID" "$BUILD_WORKFLOW_RUN_URL" "$BUILD_BUILT_AT" "$previous_image" \
                "$(printf '%s' "$previous_identity" | cut -f2)" "failed" \
                "custom migration failed; restore backup before retry" \
                "$backup_id" "$backup_artifact" 2>/dev/null || true
            return 1
        fi
    fi

    local resolved_ref="${image%@*}@${BUILD_DIGEST}"
    if ! dokku config:set --no-restart "$app" \
            APP_VERSION="$BUILD_VERSION" \
            APP_COMMIT="$BUILD_COMMIT" \
            APP_COMMIT_SHORT="$BUILD_COMMIT_SHORT" \
            APP_BUILD_CHANNEL="$BUILD_CHANNEL" \
            APP_CHANNEL="$BUILD_CHANNEL" \
            APP_IMAGE_CHANNEL="$BUILD_CHANNEL" \
            APP_WORKFLOW_RUN_ID="$BUILD_WORKFLOW_RUN_ID" \
            APP_WORKFLOW_RUN_URL="$BUILD_WORKFLOW_RUN_URL" \
            APP_BUILD_WORKFLOW_RUN="$BUILD_WORKFLOW_RUN_ID" \
            APP_WORKFLOW_RUN="$BUILD_WORKFLOW_RUN_ID" \
            APP_BUILT_AT="$BUILD_BUILT_AT" \
            APP_BUILD_AT="$BUILD_BUILT_AT" \
            APP_CREATED="$BUILD_BUILT_AT" \
            APP_IMAGE_VERSION="$BUILD_VERSION" \
            APP_IMAGE_COMMIT="$BUILD_COMMIT" \
            APP_SOURCE="$BUILD_SOURCE" \
            APP_IMAGE_REF="$BUILD_IMAGE_REF" \
            APP_IMAGE_DIGEST="$BUILD_DIGEST" \
            APP_IMAGE_RESOLVED_REF="$resolved_ref" \
            APP_DEPLOYED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; then
        restore_runtime_config "$app"
        tenant_record_failure "$tenant" "$APP_TYPE" "failed to set runtime identity" 2>/dev/null || true
        tenant_record_audit "$tenant" "$APP_TYPE" "$image" "$resolved_ref" "$BUILD_DIGEST" \
            "$BUILD_CHANNEL" "$BUILD_VERSION" "$BUILD_COMMIT" "$BUILD_COMMIT_SHORT" \
            "$BUILD_WORKFLOW_RUN_ID" "$BUILD_WORKFLOW_RUN_URL" "$BUILD_BUILT_AT" "$previous_image" \
            "$(printf '%s' "$previous_identity" | cut -f2)" "failed" \
            "failed to set runtime identity" "$backup_id" "$backup_artifact" 2>/dev/null || true
        return 1
    fi

    if ! dokku_git_from_image "$app" "$image"; then
        restore_runtime_config "$app"
        tenant_record_failure "$tenant" "$APP_TYPE" "image swap failed" 2>/dev/null || true
        tenant_record_audit "$tenant" "$APP_TYPE" "$image" "$resolved_ref" "$BUILD_DIGEST" \
            "$BUILD_CHANNEL" "$BUILD_VERSION" "$BUILD_COMMIT" "$BUILD_COMMIT_SHORT" \
            "$BUILD_WORKFLOW_RUN" "$BUILD_BUILT_AT" "$previous_image" \
            "$(printf '%s' "$previous_identity" | cut -f2)" "failed" \
            "image swap failed" "$backup_id" "$backup_artifact" 2>/dev/null || true
        return 1
    fi

    local attempt
    for ((attempt=1; attempt<=VERIFY_RETRIES; attempt++)); do
        if verify_runtime_identity "$app" "$BUILD_VERSION" "$BUILD_COMMIT" \
            "$BUILD_DIGEST" "$BUILD_IMAGE_REF" "$BUILD_CHANNEL" \
            "$BUILD_WORKFLOW_RUN_ID" "$BUILD_WORKFLOW_RUN_URL" "$BUILD_BUILT_AT"; then
            break
        fi
        if [ "$attempt" -eq "$VERIFY_RETRIES" ]; then
            error "${app}: /version identity verification failed"
            if [ "$migrations_attempted" = true ]; then
                error "${app}: automatic rollback refused; image rollback cannot restore migrated DB schema/data."
                error "Restore backup ${backup_id} (${backup_artifact}) explicitly before retry."
            elif [ -n "$previous_image" ]; then
                dokku_git_from_image "$app" "$previous_image" || true
            fi
            [ "$migrations_attempted" = true ] || restore_runtime_config "$app"
            tenant_record_failure "$tenant" "$APP_TYPE" "post-deploy /version identity verification failed" 2>/dev/null || true
            tenant_record_audit "$tenant" "$APP_TYPE" "$image" "$resolved_ref" "$BUILD_DIGEST" \
                "$BUILD_CHANNEL" "$BUILD_VERSION" "$BUILD_COMMIT" "$BUILD_COMMIT_SHORT" \
                "$BUILD_WORKFLOW_RUN" "$BUILD_BUILT_AT" "$previous_image" \
                "$(printf '%s' "$previous_identity" | cut -f2)" "failed" \
                "post-deploy /version identity verification failed" \
                "$backup_id" "$backup_artifact" 2>/dev/null || true
            return 1
        fi
        sleep "$VERIFY_DELAY"
    done

    if ! tenant_record_identity "$tenant" "$APP_TYPE" "$image" "$BUILD_IMAGE_REF" \
        "$BUILD_DIGEST" "$BUILD_CHANNEL" "$BUILD_VERSION" "$BUILD_COMMIT" \
        "$BUILD_COMMIT_SHORT" "$BUILD_WORKFLOW_RUN_ID" "$BUILD_WORKFLOW_RUN_URL" "$BUILD_BUILT_AT"; then
        error "${app}: failed to persist verified deployment identity"
        if [ "$migrations_attempted" = true ]; then
            error "${app}: automatic rollback refused after migration; restore backup ${backup_id} before retry."
        elif [ -n "$previous_image" ]; then
            dokku_git_from_image "$app" "$previous_image" || true
        fi
        [ "$migrations_attempted" = true ] || restore_runtime_config "$app"
        tenant_record_failure "$tenant" "$APP_TYPE" "failed to persist verified deployment identity" 2>/dev/null || true
        return 1
    fi
    if ! tenant_record_audit "$tenant" "$APP_TYPE" "$image" "$resolved_ref" "$BUILD_DIGEST" \
        "$BUILD_CHANNEL" "$BUILD_VERSION" "$BUILD_COMMIT" "$BUILD_COMMIT_SHORT" \
        "$BUILD_WORKFLOW_RUN_ID" "$BUILD_WORKFLOW_RUN_URL" "$BUILD_BUILT_AT" "$previous_image" \
        "$(printf '%s' "$previous_identity" | cut -f2)" "verified" "" \
        "$backup_id" "$backup_artifact" 2>/dev/null; then
        error "${app}: failed to record successful deployment audit"
        if [ -n "$previous_image" ]; then
            dokku_git_from_image "$app" "$previous_image" || true
        fi
        restore_runtime_config "$app"
        restore_previous_identity "$tenant" "$APP_TYPE" "$previous_identity"
        tenant_record_failure "$tenant" "$APP_TYPE" "deployment audit completion failed" 2>/dev/null || true
        return 1
    fi
    return 0
}

capture_runtime_config() {
    local app="$1" key
    for key in APP_VERSION APP_COMMIT APP_COMMIT_SHORT APP_BUILD_CHANNEL APP_CHANNEL \
        APP_IMAGE_CHANNEL APP_BUILD_WORKFLOW_RUN APP_WORKFLOW_RUN \
        APP_WORKFLOW_RUN_ID APP_WORKFLOW_RUN_URL APP_BUILT_AT APP_BUILD_AT APP_CREATED \
        APP_IMAGE_REF APP_IMAGE_DIGEST APP_IMAGE_RESOLVED_REF APP_IMAGE_VERSION \
        APP_IMAGE_COMMIT APP_SOURCE APP_DEPLOYED_AT; do
        PREVIOUS_CONFIG["$app:$key"]="$(dokku config:get "$app" "$key" 2>/dev/null || true)"
    done
}

restore_runtime_config() {
    local app="$1" key value
    local -a set_args=() unset_args=()
    for key in APP_VERSION APP_COMMIT APP_COMMIT_SHORT APP_BUILD_CHANNEL APP_CHANNEL \
        APP_IMAGE_CHANNEL APP_BUILD_WORKFLOW_RUN APP_WORKFLOW_RUN \
        APP_WORKFLOW_RUN_ID APP_WORKFLOW_RUN_URL APP_BUILT_AT APP_BUILD_AT APP_CREATED \
        APP_IMAGE_REF APP_IMAGE_DIGEST APP_IMAGE_RESOLVED_REF APP_IMAGE_VERSION \
        APP_IMAGE_COMMIT APP_SOURCE APP_DEPLOYED_AT; do
        value="${PREVIOUS_CONFIG["$app:$key"]:-}"
        if [ -n "$value" ]; then
            set_args+=("$key=$value")
        else
            unset_args+=("$key")
        fi
    done
    [ "${#set_args[@]}" -eq 0 ] || dokku config:set --no-restart "$app" "${set_args[@]}" || true
    [ "${#unset_args[@]}" -eq 0 ] || dokku config:unset --no-restart "$app" "${unset_args[@]}" || true
}

restore_previous_identity() {
    local tenant="$1" app_type="$2" previous="$3"
    local old_ref old_digest old_channel old_version old_commit old_short old_workflow old_workflow_url old_built
    IFS=$'\t' read -r old_ref old_digest old_channel old_version old_commit \
        old_short old_workflow old_workflow_url old_built <<< "$previous"
    if [ -n "$old_ref" ] || [ -n "$old_digest" ]; then
        tenant_record_identity "$tenant" "$app_type" "$old_ref" "$old_ref" "$old_digest" \
            "$old_channel" "$old_version" "$old_commit" "$old_short" \
            "$old_workflow" "$old_workflow_url" "$old_built" 2>/dev/null || true
    else
        tenant_clear_identity "$tenant" "$app_type" "deployment rolled back; no prior verified identity" 2>/dev/null || true
    fi
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
if ! ensure_tenant_provenance_schema; then
    error "Tenant provenance schema is unavailable; refusing an untracked deployment."
    exit 1
fi
if ! resolve_build_identity "$IMAGE"; then
    error "Image is missing or has inconsistent OCI BuildIdentity labels: $IMAGE"
    exit 1
fi

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
        HEALTH_URL="${HEALTH_URL}/healthz"
    fi

    # Wait for container to be ready
    sleep 5

    log "Health check: ${HEALTH_URL}"
    if curl -sf --max-time 10 "$HEALTH_URL" > /dev/null 2>&1; then
        log "Canary healthy ✓"
    else
        warn "Health check failed (may not have /healthz endpoint — continuing)"
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
