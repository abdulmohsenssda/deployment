#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

source scripts/lib.sh
source scripts/tenant-provenance.sh

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
COMMANDS_FILE="$TEST_DIR/commands"

docker() {
    case "$*" in
        *"config:get backend-app SERVER_PORT"*) printf '8090\n' ;;
        *"sh -lc"*)
            printf '%s\n' "$*" >> "$COMMANDS_FILE"
            printf '{"version":"v0.0.2"}'
            ;;
        *) printf '\n' ;;
    esac
}

response="$(app_version_response backend-app)"
[ "$response" = '{"version":"v0.0.2"}' ] \
    || fail "app version response did not return the probe payload"
grep -qF 'http://backend-app.web:8090/version' "$COMMANDS_FILE" \
    || fail "BuildIdentity probe did not use the app listening port"
pass "BuildIdentity probe uses the configured backend port"

echo "ALL RUNTIME PROBE TESTS PASSED"
