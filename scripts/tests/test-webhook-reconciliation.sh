#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$REPO_DIR/scripts/tests/.webhook-reconciliation.$$"
BIN_DIR="$TEST_DIR/bin"
STATE_DIR="$TEST_DIR/state"
mkdir -p "$BIN_DIR" "$STATE_DIR"
trap 'rm -rf "$TEST_DIR"' EXIT

PASS() { echo "PASS: $*"; }
FAIL() { echo "FAIL: $*"; exit 1; }
assert_eq() {
    [ "$1" = "$2" ] || FAIL "$3 (expected '$2', got '$1')"
}
assert_contains() {
    printf '%s' "$1" | grep -Fq -- "$2" || FAIL "$3"
}

# The deployment worktrees retain CRLF for compatibility with the Windows
# checkout. Normalize only the test copies so bash can execute them on Linux.
tr -d '\r' < "$REPO_DIR/scripts/lib.sh" > "$TEST_DIR/lib.sh"
tr -d '\r' < "$REPO_DIR/scripts/webhook-server.sh" > "$TEST_DIR/webhook-server.sh"
chmod +x "$TEST_DIR/webhook-server.sh"

cat > "$BIN_DIR/curl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *auth.docker.io*) printf '{"token":"test-token"}' ;;
    *) printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:new\r\n\r\n' ;;
esac
STUB
chmod +x "$BIN_DIR/curl"

DEPLOY_ARGS_FILE="$TEST_DIR/deploy.args"
cat > "$BIN_DIR/deploy-stub.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DEPLOY_ARGS_FILE:?}"
exit "${DEPLOY_RC:-0}"
STUB
chmod +x "$BIN_DIR/deploy-stub.sh"

source "$TEST_DIR/lib.sh"
export DEV_TAG=dev AUTO_PULL_STATE_DIR="$STATE_DIR"
auto_pull_digest_write backend dev sha256:old repo/api "$STATE_DIR"

run_webhook() {
    local tenant_json="${1:-}"
    local body='{"type":"backend","image":"repo/api:dev"'
    [ -z "$tenant_json" ] || body="$body,\"tenant\":\"$tenant_json\""
    body="$body}"
    printf 'POST /deploy HTTP/1.1\r\nAuthorization: Bearer secret\r\nContent-Length: %s\r\n\r\n%s' \
        "${#body}" "$body" |
        WEBHOOK_SECRET=secret \
        WEBHOOK_SERVER_TEST_MODE=1 \
        WEBHOOK_LOG_FILE="$TEST_DIR/webhook.log" \
        WEBHOOK_DEPLOY_SCRIPT="$BIN_DIR/deploy-stub.sh" \
        AUTO_PULL_STATE_DIR="$STATE_DIR" \
        DEPLOY_ARGS_FILE="$DEPLOY_ARGS_FILE" \
        PATH="$BIN_DIR:$PATH" \
        bash -c 'source "$1"; handle_request' bash "$TEST_DIR/webhook-server.sh"
}

echo "=== targeted webhook success ==="
targeted_response="$(DEPLOY_RC=0 run_webhook acme)"
assert_contains "$targeted_response" "200 OK" "targeted webhook did not succeed"
assert_eq "$(auto_pull_digest_read backend dev "$STATE_DIR")" "sha256:old" \
    "targeted webhook changed global state"
assert_eq "$(auto_pull_digest_read_for_tenant backend dev acme "$STATE_DIR")" "sha256:new" \
    "targeted webhook did not mark tenant state"
assert_contains "$(cat "$DEPLOY_ARGS_FILE")" "--tenant acme" \
    "targeted webhook did not pass tenant to deployment"
PASS "targeted success marks only the targeted tenant/component"

echo
echo "=== remaining-tenant polling ==="
assert_eq "$(auto_pull_digest_read_for_tenant backend dev acme "$STATE_DIR")" "sha256:new" \
    "targeted tenant state was not readable"
assert_eq "$(auto_pull_digest_read_for_tenant backend dev other "$STATE_DIR")" "sha256:old" \
    "remaining tenant incorrectly inherited targeted state"
PASS "remaining tenant still polls against the previous global digest"

echo
echo "=== all-tenant partial failure ==="
partial_response="$(DEPLOY_RC=1 run_webhook)"
assert_contains "$partial_response" "502 Bad Gateway" "partial all-tenant failure was not retryable"
assert_eq "$(auto_pull_digest_read backend dev "$STATE_DIR")" "sha256:old" \
    "partial all-tenant failure advanced global state"
PASS "all-tenant failure leaves reconciliation state unchanged"

echo
echo "=== all-tenant success and duplicate webhook ==="
success_response="$(DEPLOY_RC=0 run_webhook)"
assert_contains "$success_response" "200 OK" "all-tenant webhook did not succeed"
assert_eq "$(auto_pull_digest_read backend dev "$STATE_DIR")" "sha256:new" \
    "all-tenant success did not mark global state"
deploy_count="$(wc -l < "$DEPLOY_ARGS_FILE")"
duplicate_response="$(DEPLOY_RC=1 run_webhook acme)"
assert_contains "$duplicate_response" "already-reconciled" \
    "duplicate webhook was not idempotent"
assert_eq "$(wc -l < "$DEPLOY_ARGS_FILE")" "$deploy_count" \
    "duplicate webhook retriggered deployment"
PASS "all-tenant success marks global state and duplicate webhook is idempotent"

echo
echo "=== legacy state compatibility ==="
legacy_dir="$TEST_DIR/legacy"
mkdir -p "$legacy_dir"
printf 'sha256:legacy\n' > "$legacy_dir/frontend.digest"
assert_eq "$(auto_pull_digest_read_for_tenant frontend dev dev "$legacy_dir")" "sha256:legacy" \
    "legacy type-only state was not readable for a tenant"
PASS "legacy state remains compatible"

echo
echo "All webhook reconciliation tests passed."
