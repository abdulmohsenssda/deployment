#!/usr/bin/env bash
# =============================================================================
# scripts/tests/test-lib.sh — unit tests for lib.sh helpers.
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

echo "=== syntax ==="
bash -n scripts/lib.sh && pass "syntax lib.sh"

echo ""
echo "=== dokku_host_port ==="
# Test the helper with a stub `docker` so we don't need docker installed.
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Case 1: docker returns "0.0.0.0:8085" -> helper should print 8085.
cat > "$tmpdir/docker" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "port" ] && [ "$2" = "dokku" ] && [ "$3" = "80/tcp" ]; then
    echo "0.0.0.0:8085"
    echo "[::]:8085"
    exit 0
fi
exit 1
EOF
chmod +x "$tmpdir/docker"

PATH="$tmpdir:$PATH"
# shellcheck disable=SC1091
source scripts/lib.sh
got="$(dokku_host_port)"
[ "$got" = "8085" ] && pass "returns 8085 when docker reports 0.0.0.0:8085" || fail "expected 8085 got '$got'"

# Case 2: docker unavailable -> fall back to $DOKKU_PORT
cat > "$tmpdir/docker" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
DOKKU_PORT=7777 got="$(dokku_host_port)"
[ "$got" = "7777" ] && pass "falls back to \$DOKKU_PORT when docker fails" || fail "expected 7777 got '$got'"

# Case 3: no docker, no DOKKU_PORT -> fall back to 8080 hardcoded
unset DOKKU_PORT
got="$(dokku_host_port)"
[ "$got" = "8080" ] && pass "falls back to 8080 when nothing else is set" || fail "expected 8080 got '$got'"

echo ""
echo "=== MySQL admin credential resolution ==="
unset MYSQL_ADMIN_USER MYSQL_ADMIN_PASSWORD MYSQL_ROOT_USER MYSQL_ROOT_PASSWORD
[ "$(mysql_admin_user)" = "dokku_admin" ] \
    && pass "defaults to dokku_admin" \
    || fail "default admin user is incorrect"
MYSQL_ADMIN_USER=service_admin MYSQL_ADMIN_PASSWORD=service_password
[ "$(mysql_admin_user)" = "service_admin" ] && [ "$(mysql_admin_password)" = "service_password" ] \
    && mysql_admin_configured \
    && pass "uses canonical admin credentials" \
    || fail "canonical admin credentials were not resolved"
unset MYSQL_ADMIN_USER MYSQL_ADMIN_PASSWORD
MYSQL_ROOT_USER=legacy_admin MYSQL_ROOT_PASSWORD=legacy_password
[ "$(mysql_admin_user)" = "legacy_admin" ] && [ "$(mysql_admin_password)" = "legacy_password" ] \
    && pass "uses legacy root-named credentials as a compatibility fallback" \
    || fail "legacy credential fallback is broken"
unset MYSQL_ROOT_USER MYSQL_ROOT_PASSWORD
MYSQL_ROOT_PASSWORD=legacy_password
[ "$(mysql_admin_user)" = "root" ] && [ "$(mysql_admin_password)" = "legacy_password" ] \
    && pass "preserves password-only legacy root configuration" \
    || fail "password-only legacy root fallback is broken"

echo ""
echo "=== all lib.sh tests passed ==="
