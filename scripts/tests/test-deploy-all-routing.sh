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
printf '%s\n' "$*" >> "${DOCKER_LOG:?}"
case "$1" in
    pull)
        exit 1
        ;;
    exec)
        case "$*" in
            *" hostname"*) echo dokku-host ;;
            *" grep -q"*) exit 1 ;;
        esac
        ;;
esac
STUB
chmod +x "$tmpdir/docker"

cat > "$tmpdir/config.env" <<'CONFIG'
BASE_DOMAIN=example.com
PUBLIC_PROTOCOL=https
DASHBOARD_ENV=prod
IMAGE_PULL_POLICY=always
CONFIG

export DOCKER_LOG="$tmpdir/docker.log"
export PATH="$tmpdir:$PATH"
if bash scripts/deploy-all.sh repo/ifritah-api:broken \
    --type backend --tenant old --skip-canary --config "$tmpdir/config.env" \
    >/dev/null 2>&1; then
    fail "fleet deploy unexpectedly succeeded after image pull failure"
fi

routing_line="$(grep -n 'dokku domains:add old-frontend old.example.com' "$DOCKER_LOG" | head -1 | cut -d: -f1)"
pull_line="$(grep -n '^pull repo/ifritah-api:broken$' "$DOCKER_LOG" | head -1 | cut -d: -f1)"
[ -n "$routing_line" ] || fail "fleet sync did not repair tenant routing"
[ -n "$pull_line" ] || fail "fleet sync did not record failed image pull"
[ "$routing_line" -lt "$pull_line" ] \
    || fail "fleet routing repair ran after image pull"

pass "fleet sync repairs routing before image failure"
