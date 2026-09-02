#!/usr/bin/env bash
# =============================================================================
# scripts/tests/test-init-tenant-db.sh — unit tests for init-tenant-db.sh
# =============================================================================
# Tests the pure-function behavior of init-tenant-db.sh's URL construction and
# argument handling. Does NOT hit MySQL / docker / the network — asserts what
# the script WOULD do using --dry-run and stub environment.
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

echo "=== syntax ==="
bash -n scripts/init-tenant-db.sh && pass "syntax init-tenant-db.sh"

echo ""
echo "=== http_post_register uses BASEURL prefix ==="
# Source the script in a way that lets us call functions without executing main.
# We can't source directly (has side effects), so grep the source line.
if grep -qE 'local\s+basepath="\$\{BASEURL:-/api/v2\}"' scripts/init-tenant-db.sh; then
    pass "http_post_register uses \${BASEURL:-/api/v2}"
else
    fail "http_post_register does not use BASEURL prefix — will POST to wrong path"
fi

if grep -qE 'url="http://\$\{BACKEND_APP\}\.web:\$\{backend_port\}' scripts/init-tenant-db.sh; then
    pass "register targets backend directly (bypasses frontend CSRF proxy)"
else
    fail "register still goes through Dokku edge — frontend proxy will return 403 CSRF"
fi

if grep -qE 'docker run --rm --network "\$network"' scripts/init-tenant-db.sh; then
    pass "register uses docker run --network to reach backend"
else
    fail "register does not use docker network to reach backend"
fi

echo ""
echo "=== install.env is sourced (so MYSQL_ADMIN_PASSWORD is available) ==="
if grep -qE 'INSTALL_ENV_FILE=.*install\.env' scripts/init-tenant-db.sh; then
    pass "install.env is sourced after config.env"
else
    # Not a hard fail — pending PR #114
    echo "SKIP: install.env sourcing not yet merged (PR #114)"
fi

echo ""
echo "=== dry-run --seed-only prints correct URL ==="
# Set up minimum env for the script to run --dry-run without touching anything
export BASE_DOMAIN=test.example.com
export MYSQL_ADMIN_PASSWORD=stub
export DOKKU_PORT=8080
export BASEURL=/api/v2
# Use a temp config file since --dry-run still requires --config or config.env
tmpcfg=$(mktemp)
trap 'rm -f "$tmpcfg"' EXIT
cat > "$tmpcfg" <<EOF
BASE_DOMAIN=$BASE_DOMAIN
MYSQL_ADMIN_PASSWORD=$MYSQL_ADMIN_PASSWORD
DOKKU_PORT=$DOKKU_PORT
BASEURL=$BASEURL
EOF

output=$(bash scripts/init-tenant-db.sh acme --seed-only --dry-run \
    --config "$tmpcfg" \
    --env ADMIN_USER=admin \
    --env ADMIN_PASSWORD=stubpass12345 2>&1 || true)

if echo "$output" | grep -qF "Would POST /api/v2/register"; then
    pass "dry-run seed prints '/api/v2/register'"
else
    echo "--- output ---"
    echo "$output"
    echo "--- end ---"
    fail "dry-run seed did not use /api/v2/register"
fi

echo ""
echo "=== existing-tenant schema replay does not require admin credentials ==="
if grep -qF 'tenant_db_credentials_configured' scripts/init-tenant-db.sh &&
    grep -qF 'MYSQL_ADMIN_PASSWORD are only needed to create a missing tenant database' scripts/init-tenant-db.sh; then
    pass "existing-tenant replay uses tenant DB credentials before admin credentials"
else
    fail "existing-tenant replay still requires admin credentials unconditionally"
fi

if echo "$output" | grep -qF "Would POST /api/register "; then
    fail "dry-run seed still prints legacy '/api/register' (missing /v2)"
else
    pass "no legacy '/api/register' path present"
fi

echo ""
echo "=== dev-diag prints register URL ==="
if grep -q '\[dev-diag\] http_post_register url=' scripts/init-tenant-db.sh; then
    pass "http_post_register logs the URL in dev mode"
else
    fail "http_post_register does not log URL when DASHBOARD_ENV=dev"
fi

if grep -q '\[dev-diag\] register attempt=' scripts/init-tenant-db.sh; then
    pass "register retry loop logs attempts in dev mode"
else
    fail "register retry loop does not log attempts when DASHBOARD_ENV=dev"
fi

echo ""
echo "=== all tests passed ==="
