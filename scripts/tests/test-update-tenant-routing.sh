#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/docker" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    ps)
        echo dokku
        ;;
    exec)
        printf '%s\n' "$*" >> "${DOCKER_LOG:?}"
        case "$*" in
            *" hostname"*) echo dokku-host ;;
            *" grep -q"*) exit 1 ;;
        esac
        ;;
    *)
        ;;
esac
STUB
chmod +x "$tmpdir/docker"

cat > "$tmpdir/config.env" <<'CONFIG'
BASE_DOMAIN=example.com
PUBLIC_PROTOCOL=https
DASHBOARD_ENV=prod
CONFIG

export DOCKER_LOG="$tmpdir/docker.log"
export PATH="$tmpdir:$PATH"
bash scripts/update-tenant.sh old --config "$tmpdir/config.env" >/dev/null

grep -q 'dokku domains:clear old-backend' "$DOCKER_LOG" \
    || fail "update did not clear old backend domains"
grep -q 'dokku proxy:disable old-backend' "$DOCKER_LOG" \
    || fail "update did not disable old backend proxy"
grep -q 'dokku domains:add old-frontend old.example.com' "$DOCKER_LOG" \
    || fail "update did not assign current frontend domain"
grep -q 'APP_DOMAIN=old.example.com API_URL=https://old.example.com/api' "$DOCKER_LOG" \
    || fail "update did not refresh persisted frontend URLs"
grep -q 'dokku ps:restart old-frontend' "$DOCKER_LOG" \
    || fail "update did not restart frontend after URL refresh"

pass "tenant update repairs persisted routing"
