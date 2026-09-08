#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

source scripts/tenant-provenance.sh

IMAGE_DIGEST="sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

docker() {
    local format=""
    for arg in "$@"; do
        case "$arg" in --format=*) format="${arg#--format=}" ;; esac
    done
    case "$format" in
        *RepoDigests*) echo "example/api@${IMAGE_DIGEST}" ;;
        *channel*) echo "release" ;;
        *workflow_run_url*) echo "https://github.com/example/api/actions/runs/42" ;;
        *workflow_run_id*|*workflow*) echo "42" ;;
        *source*) echo "https://github.com/example/api" ;;
        *image_ref*|*ref.name*) echo "example/api:v1.2.3" ;;
        *created*|*built*) echo "2026-09-07T10:00:00Z" ;;
        *version*) echo "v1.2.3" ;;
        *revision*|*commit*) echo "0123456789abcdef0123456789abcdef01234567" ;;
        *digest*) echo "$IMAGE_DIGEST" ;;
        *) echo "" ;;
    esac
}

echo "=== missing labels fail closed ==="
docker() {
    local format=""
    for arg in "$@"; do
        case "$arg" in --format=*) format="${arg#--format=}" ;; esac
    done
    case "$format" in *RepoDigests*) echo "example/api@${IMAGE_DIGEST}" ;; *) echo "" ;; esac
}
if resolve_build_identity example/api:v1.2.3; then
    fail "missing OCI labels were accepted"
else
    pass "missing OCI labels are rejected"
fi

echo "=== mismatched digest fails closed ==="
docker() {
    local format=""
    for arg in "$@"; do
        case "$arg" in --format=*) format="${arg#--format=}" ;; esac
    done
    case "$format" in
        *RepoDigests*) echo "example/api@${IMAGE_DIGEST}" ;;
        *channel*) echo "release" ;;
        *workflow_run_url*) echo "https://github.com/example/api/actions/runs/42" ;;
        *workflow_run_id*|*workflow*) echo "42" ;;
        *source*) echo "https://github.com/example/api" ;;
        *image_ref*|*ref.name*) echo "example/api:v1.2.3" ;;
        *created*|*built*) echo "2026-09-07T10:00:00Z" ;;
        *version*) echo "v1.2.3" ;;
        *revision*|*commit*) echo "0123456789abcdef0123456789abcdef01234567" ;;
        *digest*) echo "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" ;;
        *) echo "" ;;
    esac
}
if resolve_build_identity example/api:v1.2.3; then
    fail "mismatched digest label was accepted"
else
    pass "mismatched digest label is rejected"
fi

echo "=== successful identity and /version verification ==="
docker() {
    local format=""
    for arg in "$@"; do
        case "$arg" in --format=*) format="${arg#--format=}" ;; esac
    done
    case "$format" in
        *RepoDigests*) echo "example/api@${IMAGE_DIGEST}" ;;
        *channel*) echo "release" ;;
        *workflow_run_url*) echo "https://github.com/example/api/actions/runs/42" ;;
        *workflow_run_id*|*workflow*) echo "42" ;;
        *source*) echo "https://github.com/example/api" ;;
        *image_ref*|*ref.name*) echo "example/api:v1.2.3" ;;
        *created*|*built*) echo "2026-09-07T10:00:00Z" ;;
        *version*) echo "v1.2.3" ;;
        *revision*|*commit*) echo "0123456789abcdef0123456789abcdef01234567" ;;
        *digest*) echo "$IMAGE_DIGEST" ;;
        *) echo "" ;;
    esac
}
resolve_build_identity example/api:v1.2.3 || fail "valid BuildIdentity was rejected"
app_version_response() {
    printf '%s' '{"version":"v1.2.3","commit":"0123456789abcdef0123456789abcdef01234567","digest":"'"$IMAGE_DIGEST"'","image_ref":"example/api:v1.2.3","channel":"release","workflow_run_id":"42","workflow_run_url":"https://github.com/example/api/actions/runs/42","built_at":"2026-09-07T10:00:00Z"}'
}
verify_runtime_identity api-app "$BUILD_VERSION" "$BUILD_COMMIT" "$BUILD_DIGEST" \
    "$BUILD_IMAGE_REF" "$BUILD_CHANNEL" "$BUILD_WORKFLOW_RUN_ID" "$BUILD_WORKFLOW_RUN_URL" "$BUILD_BUILT_AT" \
    || fail "matching /version identity was rejected"
pass "matching /version identity is accepted"
app_version_response() {
    printf '%s' '{"version":"v1.2.3","commit":"ffffffffffffffffffffffffffffffffffffffff","digest":"'"$IMAGE_DIGEST"'","image_ref":"example/api:v1.2.3","channel":"release","workflow_run_id":"42","built_at":"2026-09-07T10:00:00Z"}'
}
if verify_runtime_identity api-app "$BUILD_VERSION" "$BUILD_COMMIT" "$BUILD_DIGEST" \
    "$BUILD_IMAGE_REF" "$BUILD_CHANNEL" "$BUILD_WORKFLOW_RUN_ID" "$BUILD_WORKFLOW_RUN_URL" "$BUILD_BUILT_AT"; then
    fail "mismatched /version commit was accepted"
else
    pass "mismatched /version commit is rejected"
fi

echo "=== migration, rollback, and component-only guards ==="
grep -q 'init-tenant-db.sh' scripts/update-tenant.sh &&
grep -q -- '--schema-only' scripts/update-tenant.sh \
    || fail "backend migration replay guard missing"
grep -q 'rollback_component' scripts/update-tenant.sh \
    || fail "partial swap rollback guard missing"
grep -q 'APP_VERSION=' scripts/update-tenant.sh \
    || fail "APP_VERSION runtime identity missing"
grep -q 'APP_COMMIT=' scripts/update-tenant.sh \
    || fail "APP_COMMIT runtime identity missing"
grep -q 'APP_IMAGE_CHANNEL=' scripts/update-tenant.sh \
    || fail "APP_IMAGE_CHANNEL runtime identity missing"
grep -q 'APP_WORKFLOW_RUN_ID=' scripts/update-tenant.sh \
    || fail "APP_WORKFLOW_RUN_ID runtime identity missing"
grep -q 'frontend' scripts/update-tenant.sh \
    || fail "component-only frontend update path missing"
grep -q 'IFS=.*workflow_url.*image_ref' scripts/create-tenant.sh \
    || fail "create-tenant must preserve workflow URL and image ref field order"
grep -q 'APP_IMAGE_VERSION="\$version"' scripts/create-tenant.sh \
    || fail "create-tenant must keep semantic version separate from Docker tag"
grep -q 'APP_IMAGE_TAG=' scripts/create-tenant.sh \
    || fail "create-tenant must persist the Docker tag separately"
! grep -R -q '/api/health' scripts/*.sh templates REQUIREMENTS.md \
    || fail "legacy /api/health deployment probe remains"
[ "$(grep -c '"workflow_run_id":"%s"' scripts/status.sh)" -eq 1 ] \
    || fail "status JSON does not have one canonical identity serialization"
pass "migration, rollback, and component-only guards are present"

echo "ALL TENANT PROVENANCE TESTS PASSED"
