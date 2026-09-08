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
#   --routing-only             Reconcile persisted domain/URL state and exit.
#   --config <path>            Path to config.env file (default: ../config.env)
#
# Routing behavior:
#   Every update reconciles the persisted frontend domain, APP_DOMAIN, and
#   API_URL with the current BASE_DOMAIN. This repairs tenants created before
#   a base-domain change. Use --routing-only for a URL repair without images;
#   use post-merge-cleanup.sh for a fleet-wide repair without an update.
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
# Image updates are provenance-verified and transactional as far as Dokku can
# make them: backend migrations run before the image swap, every app reports
# the expected /version identity, and a failed component restores the prior
# image/config where a prior image exists.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/tenant-provenance.sh"

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
VERIFY_RETRIES="${TENANT_VERIFY_RETRIES:-15}"
VERIFY_DELAY="${TENANT_VERIFY_DELAY:-2}"

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
ROUTING_ONLY=false
MIGRATIONS_APPLIED=false
DB_BACKUP_ID=""
DB_BACKUP_ARTIFACT=""
declare -a ENV_VARS=()
declare -A COMPONENT_IDENTITY=()
declare -A COMPONENT_SOURCE=()
declare -A PREVIOUS_IMAGE=()
declare -A PREVIOUS_CONFIG=()
declare -A PREVIOUS_DB_IDENTITY=()
declare -A DEPLOYED_COMPONENT=()

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
                return 1
            fi
            ;;
        *)
            error "IMAGE_PULL_POLICY must be 'always', 'missing', or 'never' (got: $IMAGE_PULL_POLICY)"
            return 1
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

current_app_image() {
    local app="$1" image
    image="$(dokku git:report "$app" 2>/dev/null |
        awk -F': ' 'tolower($1) ~ /source-image/ {print $2; exit}' || true)"
    if [ -z "$image" ]; then
        image="$(dokku config:get "$app" APP_IMAGE_REF 2>/dev/null | awk 'NF {print; exit}' || true)"
    fi
    printf '%s' "$image"
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

record_failure() {
    local component="$1" requested="$2" message="$3"
    local values="${COMPONENT_IDENTITY[$component]:-}"
    local channel="" version="" commit_sha="" commit_short="" workflow="" workflow_url=""
    local image_ref="" digest="" built_at="" previous_ref="" previous_digest=""
    if [ -n "$values" ]; then
        IFS=$'\t' read -r channel version commit_sha commit_short workflow workflow_url \
            image_ref digest built_at <<< "$values"
    fi
    local resolved_ref="${requested%@*}@${digest}"
    IFS=$'\t' read -r previous_ref previous_digest _ <<< "${PREVIOUS_DB_IDENTITY[$component]:-}"
    tenant_record_failure "$TENANT_NAME" "$component" "$message" 2>/dev/null || true
    tenant_record_audit "$TENANT_NAME" "$component" "$requested" "$resolved_ref" "$digest" \
        "$channel" "$version" "$commit_sha" "$commit_short" "$workflow" "$workflow_url" "$built_at" \
        "$previous_ref" "$previous_digest" "failed" "$message" \
        "$DB_BACKUP_ID" "$DB_BACKUP_ARTIFACT" 2>/dev/null || true
}

rollback_component() {
    local component="$1" app image
    app="${TENANT_NAME}-${component}"
    image="${PREVIOUS_IMAGE[$component]:-}"
    if [ "$component" = "backend" ] && $MIGRATIONS_APPLIED; then
        error "${app}: automatic image rollback refused after migrations; restoring the image alone cannot restore DB schema/data."
        error "Restore verified backup ${DB_BACKUP_ID:-<unknown>} (${DB_BACKUP_ARTIFACT:-<unknown>}) explicitly, then retry the rollback."
        tenant_record_failure "$TENANT_NAME" "$component" \
            "rollback refused: database migrations applied; explicit backup restore required" 2>/dev/null || true
        return 2
    fi
    if [ -z "$image" ]; then
        warn "${app}: no previous image is recorded; cannot perform image rollback"
        restore_runtime_config "$app"
        return 1
    fi
    log "Rolling back ${app} to ${image}"
    if ! dokku_git_from_image "$app" "$image"; then
        error "${app}: rollback failed"
        restore_runtime_config "$app"
        return 1
    fi
    restore_runtime_config "$app"
    IFS=$'\t' read -r old_ref old_digest _ <<< "${PREVIOUS_DB_IDENTITY[$component]:-}"
    if [ -n "$old_ref" ] || [ -n "$old_digest" ]; then
        # Keep the durable current identity equal to the last-known-good image.
        IFS=$'\t' read -r old_ref old_digest old_channel old_version old_commit \
            old_short old_workflow old_workflow_url old_built <<< "${PREVIOUS_DB_IDENTITY[$component]}"
        tenant_record_identity "$TENANT_NAME" "$component" "$old_ref" "$old_ref" \
            "$old_digest" "$old_channel" "$old_version" "$old_commit" "$old_short" \
            "$old_workflow" "$old_workflow_url" "$old_built" 2>/dev/null || true
    else
        tenant_clear_identity "$TENANT_NAME" "$component" "deployment rolled back; no prior verified identity" 2>/dev/null || true
    fi
    return 0
}

verify_component() {
    local component="$1" app="$2" values="$3"
    local channel version commit_sha commit_short workflow workflow_url image_ref digest built_at
    IFS=$'\t' read -r channel version commit_sha commit_short workflow workflow_url \
        image_ref digest built_at <<< "$values"
    local attempt
    for ((attempt=1; attempt<=VERIFY_RETRIES; attempt++)); do
        if verify_runtime_identity "$app" "$version" "$commit_sha" "$digest" \
            "$image_ref" "$channel" "$workflow" "$workflow_url" "$built_at"; then
            return 0
        fi
        [ "$attempt" -lt "$VERIFY_RETRIES" ] && sleep "$VERIFY_DELAY"
    done
    error "${app}: /version did not report the expected BuildIdentity"
    return 1
}

deploy_component() {
    local component="$1" image="$2" app="${TENANT_NAME}-${1}"
    local values="${COMPONENT_IDENTITY[$component]}"
    local channel version commit_sha commit_short workflow workflow_url image_ref digest built_at
    local resolved_ref="${image%@*}@${digest}"
    IFS=$'\t' read -r channel version commit_sha commit_short workflow workflow_url \
        image_ref digest built_at <<< "$values"

    if ! tenant_record_audit "$TENANT_NAME" "$component" "$image" "$resolved_ref" "$digest" \
        "$channel" "$version" "$commit_sha" "$commit_short" "$workflow" "$workflow_url" "$built_at" \
        "${PREVIOUS_IMAGE[$component]:-}" \
        "$(printf '%s' "${PREVIOUS_DB_IDENTITY[$component]:-}" | cut -f2)" \
        "started" "" "$DB_BACKUP_ID" "$DB_BACKUP_ARTIFACT" 2>/dev/null; then
        error "${app}: deployment audit is unavailable; refusing an untracked swap"
        record_failure "$component" "$image" "deployment audit start failed"
        return 1
    fi

    log "Deploying ${component}: ${image} (${digest})"
    local resolved_ref="${image%@*}@${digest}"
    if ! dokku config:set --no-restart "$app" \
        APP_VERSION="$version" \
        APP_COMMIT="$commit_sha" \
        APP_COMMIT_SHORT="$commit_short" \
        APP_BUILD_CHANNEL="$channel" \
        APP_CHANNEL="$channel" \
        APP_IMAGE_CHANNEL="$channel" \
        APP_SOURCE="${COMPONENT_SOURCE[$component]:-}" \
        APP_WORKFLOW_RUN_ID="$workflow" \
        APP_WORKFLOW_RUN_URL="$workflow_url" \
        APP_BUILD_WORKFLOW_RUN="$workflow" \
        APP_WORKFLOW_RUN="$workflow" \
        APP_BUILT_AT="$built_at" \
        APP_BUILD_AT="$built_at" \
        APP_CREATED="$built_at" \
        APP_IMAGE_VERSION="$version" \
        APP_IMAGE_COMMIT="$commit_sha" \
        APP_IMAGE_REF="$image_ref" \
        APP_IMAGE_DIGEST="$digest" \
        APP_IMAGE_RESOLVED_REF="$resolved_ref" \
        APP_DEPLOYED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; then
        record_failure "$component" "$image" "failed to set runtime identity"
        restore_runtime_config "$app"
        return 1
    fi
    if ! dokku_git_from_image "$app" "$image"; then
        record_failure "$component" "$image" "Dokku image swap failed"
        rollback_component "$component" || true
        return 1
    fi
    if ! verify_component "$component" "$app" "$values"; then
        record_failure "$component" "$image" "post-deploy /version identity verification failed"
        rollback_component "$component" || true
        return 1
    fi
    if ! tenant_record_identity "$TENANT_NAME" "$component" "$image" "$image_ref" \
        "$digest" "$channel" "$version" "$commit_sha" "$commit_short" \
        "$workflow" "$workflow_url" "$built_at"; then
        record_failure "$component" "$image" "failed to persist verified deployment identity"
        rollback_component "$component" || true
        return 1
    fi
    if ! tenant_record_audit "$TENANT_NAME" "$component" "$image" "$resolved_ref" "$digest" \
        "$channel" "$version" "$commit_sha" "$commit_short" "$workflow" "$workflow_url" "$built_at" \
        "${PREVIOUS_IMAGE[$component]:-}" \
        "$(printf '%s' "${PREVIOUS_DB_IDENTITY[$component]:-}" | cut -f2)" \
        "verified" "" "$DB_BACKUP_ID" "$DB_BACKUP_ARTIFACT" 2>/dev/null; then
        error "${app}: failed to record successful deployment audit"
        rollback_component "$component" || true
        record_failure "$component" "$image" "deployment audit completion failed"
        return 1
    fi
    DEPLOYED_COMPONENT["$component"]=1
    return 0

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
        --routing-only)      ROUTING_ONLY=true; shift ;;
        --config)            shift 2 ;;  # already parsed above
        -*)                  error "Unknown option: $1"; exit 1 ;;
        *)                   [ -z "$TENANT_NAME" ] && TENANT_NAME="$1"; shift ;;
    esac
done

if [ -z "$TENANT_NAME" ]; then
    echo "Usage: $0 <tenant-name> [--backend-image <image>] [--frontend-image <image>]"
    exit 1
fi
TENANT_NAME="$(tenant_full_name "$TENANT_NAME")" || exit 1
BASE_DOMAIN="${BASE_DOMAIN:?BASE_DOMAIN not set in config.env}"
PUBLIC_TENANT_URL="$(public_tenant_url "$TENANT_NAME")" || exit 1

BACKEND_APP="${TENANT_NAME}-backend"
FRONTEND_APP="${TENANT_NAME}-frontend"

# Reconcile persisted routing before any image pull, migration, or deploy.
# This makes the configured BASE_DOMAIN authoritative even when a later
# update step fails.
log "Synchronizing tenant routing: ${PUBLIC_TENANT_URL}"
reconcile_tenant_routing "$TENANT_NAME"

if $ROUTING_ONLY; then
    log "Routing synchronized. No image deployment requested."
    exit 0
fi

# ---- Set env vars ----

if [ -n "$BACKEND_IMAGE" ] || [ -n "$FRONTEND_IMAGE" ]; then
    if ! ensure_tenant_provenance_schema; then
        error "Tenant provenance schema is unavailable; refusing an untracked deployment."
        exit 1
    fi
fi
for ev in "${ENV_VARS[@]+"${ENV_VARS[@]}"}"; do
    if [[ "$ev" == *"="* ]]; then
        log "Setting env: $ev"
        dokku config:set --no-restart "$BACKEND_APP" "$ev"
    fi
done

# ---- Deploy new images ----
# Pull each image first so image_version_label can inspect the manifest, then
# run the drift preflight before the provenance-verified swaps.
if [ -n "$BACKEND_IMAGE" ]; then
    ensure_update_image_available "$BACKEND_IMAGE"
fi
if [ -n "$FRONTEND_IMAGE" ]; then
    ensure_update_image_available "$FRONTEND_IMAGE"
fi

assert_image_versions_match

for component in backend frontend; do
    image="${component^^}_IMAGE"
    image="${!image:-}"
    [ -n "$image" ] || continue
    app="${TENANT_NAME}-${component}"
    PREVIOUS_IMAGE["$component"]="$(current_app_image "$app")"
    capture_runtime_config "$app"
    PREVIOUS_DB_IDENTITY["$component"]="$(tenant_current_identity "$TENANT_NAME" "$component" || true)"
    if ! ensure_update_image_available "$image"; then
        record_failure "$component" "$image" "image pull/availability check failed"
        exit 1
    fi
    if ! resolve_build_identity "$image"; then
        error "${image}: missing or inconsistent OCI BuildIdentity labels"
        record_failure "$component" "$image" "missing or inconsistent OCI BuildIdentity labels"
        exit 1
    fi
    COMPONENT_IDENTITY["$component"]="$(provenance_identity_tsv)"
    COMPONENT_SOURCE["$component"]="$BUILD_SOURCE"
done

if [ -n "$BACKEND_IMAGE" ]; then
    if $SKIP_MIGRATIONS && ! provenance_override_enabled; then
        error "--skip-migrations is only allowed with TENANT_PROVENANCE_OVERRIDE=1 in a non-production environment."
        record_failure backend "$BACKEND_IMAGE" "unsafe migration bypass refused"
        exit 1
    fi
    if ! $SKIP_MIGRATIONS; then
        log "Creating verified pre-migration database backup for ${TENANT_NAME}"
        if ! DB_BACKUP_INFO="$(create_verified_tenant_db_backup "$TENANT_NAME" "$CONFIG_FILE")"; then
            error "Verified tenant DB backup could not be created; refusing migrations and image swap."
            record_failure backend "$BACKEND_IMAGE" "verified pre-migration database backup unavailable"
            exit 1
        fi
        IFS=$'\t' read -r DB_BACKUP_ID DB_BACKUP_ARTIFACT _ <<< "$DB_BACKUP_INFO"
        if [ -z "$DB_BACKUP_ID" ] || [ -z "$DB_BACKUP_ARTIFACT" ]; then
            error "Pre-migration backup identity is incomplete; refusing migrations and image swap."
            record_failure backend "$BACKEND_IMAGE" "pre-migration backup identity incomplete"
            exit 1
        fi
        log "Verified DB backup: ${DB_BACKUP_ID}"
        log "Replaying schema/migrations from ${BACKEND_IMAGE} before backend swap"
        if ! "$SCRIPT_DIR/init-tenant-db.sh" "$TENANT_NAME" \
            --schema-only --backend-image "$BACKEND_IMAGE" --config "$CONFIG_FILE"; then
            error "Migration replay failed; refusing to swap the backend image."
            error "Restore verified backup ${DB_BACKUP_ID} (${DB_BACKUP_ARTIFACT}) before retrying."
            record_failure backend "$BACKEND_IMAGE" \
                "migration replay failed; restore pre-migration backup before retry"
            exit 1
        fi
        MIGRATIONS_APPLIED=true
    else
        warn "Skipping backend migrations under explicit non-production override."
        tenant_record_audit "$TENANT_NAME" backend "$BACKEND_IMAGE" "" "" \
            "" "" "" "" "" "" "" "" "override" \
            "--skip-migrations under non-production override" "" "" 2>/dev/null || true
    fi
fi

if [ -n "$BACKEND_IMAGE" ]; then
    if ! deploy_component backend "$BACKEND_IMAGE"; then
        exit 1
    fi
fi
if [ -n "$FRONTEND_IMAGE" ]; then
    if ! deploy_component frontend "$FRONTEND_IMAGE"; then
        if [ -n "${DEPLOYED_COMPONENT[backend]:-}" ]; then
            if $MIGRATIONS_APPLIED; then
                error "Frontend failed after backend migration/swap; backend remains deployed and tenant is degraded."
                error "Automatic backend rollback is refused because it cannot restore database schema/data from the backup."
                tenant_record_failure "$TENANT_NAME" frontend \
                    "frontend swap failed; backend retained because DB rollback is not automatic" 2>/dev/null || true
            else
                warn "Frontend failed after backend swap; restoring backend last-known-good image."
                rollback_component backend || true
            fi
        fi
        exit 1
    fi
fi

if [ -n "$SCALE" ]; then
    log "Scaling backend to $SCALE instances"
    dokku ps:scale "$BACKEND_APP" web="$SCALE"
fi

if $RESTART; then
    log "Restarting tenant..."
    dokku ps:restart "$BACKEND_APP"
    dokku ps:restart "$FRONTEND_APP"
else
    # APP_DOMAIN/API_URL are runtime config, so apply them even when no
    # image update or explicit --restart was requested.
    if [ "$ROUTING_RESTARTED" != "true" ]; then
        dokku ps:restart "$FRONTEND_APP"
    fi
fi

log "Done. Verified deployment identity persisted for ${TENANT_NAME}."
