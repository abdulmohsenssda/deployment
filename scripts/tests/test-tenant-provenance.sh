#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

source scripts/lib.sh
source scripts/tenant-provenance.sh

IMAGE_DIGEST="sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

echo "=== portable schema column helper ==="
schema_calls_file="$(mktemp)"
trap 'rm -f "$schema_calls_file"' EXIT
schema_column_exists=0
run_mysql() {
    local args="$*"
    printf '%s\n' "$args" >> "$schema_calls_file"
    if [[ "$args" == *"information_schema.columns"* ]]; then
        printf '%s\n' "$schema_column_exists"
    fi
}
mysql_add_column_if_missing test_db tenant sample_column "VARCHAR(8) NOT NULL DEFAULT ''" \
    || fail "missing schema column was not added"
grep -q 'ALTER TABLE `tenant` ADD COLUMN `sample_column` VARCHAR(8)' "$schema_calls_file" ||
    fail "portable schema helper did not issue a column ALTER"

: > "$schema_calls_file"
schema_column_exists=1
mysql_add_column_if_missing test_db tenant sample_column "VARCHAR(8) NOT NULL DEFAULT ''" \
    || fail "existing schema column was not accepted"
[ "$(grep -c 'information_schema.columns' "$schema_calls_file")" -eq 1 ] ||
    fail "existing schema column was not checked"
! grep -q 'ALTER TABLE `tenant` ADD COLUMN `sample_column`' "$schema_calls_file" ||
    fail "existing schema column triggered an unnecessary ALTER"
! grep -q 'ADD COLUMN IF NOT EXISTS `' \
    scripts/lib.sh scripts/setup.sh scripts/tenant-provenance.sh \
    docs/tenant-recovery-hockun2.md ||
    fail "unsupported ADD COLUMN IF NOT EXISTS migration remains"
pass "portable schema migration is used"

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

echo "=== app probes use the container listening port ==="
docker() {
    case "$*" in
        *"config:get api-app SERVER_PORT"*) printf '8090\n' ;;
        *"config:get frontend-app SERVER_PORT"*) printf '\n' ;;
        *"config:get frontend-app PORT"*) printf '8000\n' ;;
        *"config:get legacy-app SERVER_PORT"*) printf '\n' ;;
        *"config:get legacy-app PORT"*) printf '\n' ;;
        *"ports:report legacy-app"*) printf 'Ports map: http:80:8123\n' ;;
        *"config:get fallback-app"*|*"ports:report fallback-app"*) exit 1 ;;
        *) printf '\n' ;;
    esac
}
assert_probe_port() {
    local app="$1" expected="$2" actual
    actual="$(dokku_app_port "$app")"
    [ "$actual" = "$expected" ] || fail "${app} probe port: expected ${expected}, got ${actual}"
}
assert_probe_port api-app 8090
assert_probe_port frontend-app 8000
assert_probe_port legacy-app 8123
assert_probe_port fallback-app 80
pass "runtime probes resolve backend, frontend, and legacy ports"

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
