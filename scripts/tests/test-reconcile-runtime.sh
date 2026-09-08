#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$REPO_DIR/scripts/tests/.reconcile-runtime.$$"
BIN_DIR="$TEST_DIR/bin"
STATE_DIR="$TEST_DIR/state"
mkdir -p "$BIN_DIR" "$STATE_DIR"
trap 'rm -rf "$TEST_DIR"' EXIT

PASS() { echo "PASS: $*"; }
FAIL() { echo "FAIL: $*"; exit 1; }
assert_eq() {
    [ "$1" = "$2" ] || FAIL "$3 (expected '$2', got '$1')"
}

echo "=== 1. changed scripts parse ==="
for f in scripts/lib.sh scripts/auto-pull.sh scripts/webhook-server.sh scripts/setup.sh scripts/status.sh; do
    bash -n "$REPO_DIR/$f" && PASS "syntax $f" || FAIL "syntax $f"
done

echo
echo "=== 2. canonical digest state and transitions ==="
(
    cd "$REPO_DIR"
    export AUTO_PULL_STATE_DIR="$STATE_DIR" DEV_TAG=dev
    # shellcheck source=../lib.sh
    source scripts/lib.sh
    path="$(auto_pull_digest_path backend dev)"
    assert_eq "$path" "$STATE_DIR/backend-dev.digest" "canonical backend/dev state path"
    auto_pull_digest_write backend dev sha256:first repo/api "$STATE_DIR"
    assert_eq "$(auto_pull_digest_read backend dev "$STATE_DIR")" "sha256:first" "first digest is readable"
    auto_pull_digest_write backend dev sha256:second repo/api "$STATE_DIR"
    assert_eq "$(auto_pull_digest_read backend dev "$STATE_DIR")" "sha256:second" "digest transition is readable"
    grep -q '^last_seen_digest=sha256:second$' "$path" || FAIL "last-seen digest missing"
    grep -q '^last_deployed_digest=sha256:second$' "$path" || FAIL "last-deployed digest missing"
    [ ! -e "${path}.$$" ] || FAIL "atomic state temporary file was left behind"
    printf 'sha256:legacy\n' > "$STATE_DIR/frontend.digest"
    assert_eq "$(auto_pull_digest_read frontend dev "$STATE_DIR")" "sha256:legacy" "legacy state remains compatible"
)
PASS "canonical state path, transition, atomic write, and legacy read"

echo
echo "=== 3. cron install and status diagnostics ==="
cat > "$BIN_DIR/crontab" <<'STUB'
#!/usr/bin/env bash
state="${CRONTAB_STATE:?}"
if [ "${CRONTAB_ERROR:-0}" = "1" ]; then
    echo "crontab permission denied" >&2
    exit 2
fi
if [ "$1" = "-l" ]; then
    [ -f "$state" ] || { echo "no crontab for test-user" >&2; exit 1; }
    cat "$state"
    exit 0
fi
if [ "$1" = "-" ]; then
    cat > "$state"
    exit 0
fi
exit 2
STUB
chmod +x "$BIN_DIR/crontab"
printf '# unrelated entry\n*/5 * * * * /opt/other.sh\n*/2 * * * * /old/auto-pull.sh\n' > "$TEST_DIR/crontab"
(
    cd "$REPO_DIR"
    export PATH="$BIN_DIR:$PATH" CRONTAB_STATE="$TEST_DIR/crontab"
    source scripts/lib.sh
    ensure_auto_pull_schedule "$REPO_DIR/scripts/auto-pull.sh" "$TEST_DIR/config.env"
    grep -q '^# unrelated entry$' "$CRONTAB_STATE" || FAIL "unrelated cron entry was removed"
    ! grep -q '/old/auto-pull.sh' "$CRONTAB_STATE" || FAIL "old auto-pull entry was not replaced"
    grep -q "$REPO_DIR/scripts/auto-pull.sh" "$CRONTAB_STATE" || FAIL "canonical auto-pull entry missing"
    assert_eq "$(auto_pull_cron_status "$REPO_DIR/scripts/auto-pull.sh" | cut -f1)" "active" "active cron status"
    rm -f "$CRONTAB_STATE"
    assert_eq "$(auto_pull_cron_status "$REPO_DIR/scripts/auto-pull.sh" | cut -f1)" "absent" "missing cron status"
    export CRONTAB_ERROR=1
    assert_eq "$(auto_pull_cron_status "$REPO_DIR/scripts/auto-pull.sh" | cut -f1)" "error" "cron read error status"
)
PASS "cron setup preserves unrelated entries and reports active/absent/error"

echo
echo "=== 4. Docker Hub failures are non-success ==="
cat > "$BIN_DIR/curl" <<'STUB'
#!/usr/bin/env bash
exit 7
STUB
chmod +x "$BIN_DIR/curl"
(
    cd "$REPO_DIR"
    if PATH="$BIN_DIR:$PATH" bash -c 'source scripts/lib.sh; get_remote_digest repo/api dev'; then
        FAIL "digest lookup failure returned success"
    fi
)
PASS "digest lookup failure is surfaced"
cat > "$BIN_DIR/curl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *auth.docker.io*) printf '{"token":"test-token"}' ;;
    *) printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:test\r\n\r\n' ;;
esac
STUB
chmod +x "$BIN_DIR/curl"
DIGEST="$(PATH="$BIN_DIR:$PATH" bash -c 'source scripts/lib.sh; get_remote_digest repo/api dev')"
assert_eq "$DIGEST" "sha256:test" "mutable tag resolves to digest"
PASS "mutable dev tag resolves to a manifest digest"

echo
echo "=== 5. webhook and poller share state writer ==="
grep -q 'auto_pull_digest_read' scripts/auto-pull.sh \
    && grep -q 'auto_pull_digest_write' scripts/auto-pull.sh \
    && grep -q 'auto_pull_digest_write' scripts/webhook-server.sh \
    && ! grep -q 'digest_dir}/${app_type}.digest' scripts/webhook-server.sh \
    && PASS "webhook and poller use canonical state helpers" \
    || FAIL "webhook/poller state paths diverged"
grep -q 'return 1' scripts/auto-pull.sh \
    && grep -q '502 Bad Gateway' scripts/webhook-server.sh \
    && PASS "polling/webhook failures remain retryable" \
    || FAIL "failure responses are not explicit"

echo
echo "All reconciliation runtime tests passed."
