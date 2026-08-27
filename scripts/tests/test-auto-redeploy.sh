#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"
source scripts/lib.sh

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

STATE_DIR="$REPO_DIR/.test-auto-redeploy.$$"
trap 'rm -rf "$STATE_DIR"' EXIT
mkdir -p "$STATE_DIR"

TENANT_STATE_DIR="$STATE_DIR"
AUTO_REDEPLOY_DISABLED=""
printf '{\n  "auto_redeploy": false\n}\n' > "$STATE_DIR/acme.json"
if tenant_auto_redeploy_enabled acme; then
    fail "dashboard state file did not disable auto-redeploy"
fi
pass "dashboard state disables auto-redeploy"

printf '{\n  "auto_redeploy": true\n}\n' > "$STATE_DIR/acme.json"
tenant_auto_redeploy_enabled acme || fail "enabled dashboard state was rejected"
pass "dashboard state enables auto-redeploy"

AUTO_REDEPLOY_DISABLED="acme"
tenant_auto_redeploy_enabled acme && fail "compatibility disable list was ignored"
pass "compatibility disable list disables auto-redeploy"

echo "ALL AUTO-REDEPLOY TESTS PASSED"
