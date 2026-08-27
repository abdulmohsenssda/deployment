#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

plan() {
    bash scripts/deployctl.sh --plan "$@"
}

expect_plan() {
    local expected="$1"
    shift
    local got
    got="$(plan "$@")"
    if [ "$got" = "$expected" ]; then
        pass "$*"
    else
        echo "got:      $got"
        echo "expected: $expected"
        fail "$*"
    fi
}

echo "=== deployctl syntax ==="
bash -n scripts/deployctl.sh && pass "syntax deployctl"

echo
echo "=== deployctl command mapping ==="
expect_plan "bash scripts/create-tenant.sh acme --backend-image repo/ifritah-api:v1 --frontend-image repo/ifritah-web:v1" \
    tenant create acme --backend-image repo/ifritah-api:v1 --frontend-image repo/ifritah-web:v1

expect_plan "bash scripts/update-tenant.sh acme --restart --config /opt/deployment/config.prod.env" \
    --config /opt/deployment/config.prod.env tenant update acme --restart

got="$(CONFIG_FILE=/opt/deployment/config.prod.env plan tenant update acme --restart)"
if [ "$got" = "bash scripts/update-tenant.sh acme --restart --config /opt/deployment/config.prod.env" ]; then
    pass "CONFIG_FILE env is preserved"
else
    echo "got:      $got"
    fail "CONFIG_FILE env is preserved"
fi

expect_plan "bash scripts/status.sh --tenant acme --json --config /opt/deployment/config.prod.env" \
    --config /opt/deployment/config.prod.env tenant status acme --json

expect_plan "bash scripts/tail-logs.sh --tenant acme --type backend --since 1h" \
    tenant logs acme --type backend --since 1h

expect_plan "bash scripts/deploy-all.sh repo/ifritah-api:v2 --type backend --tenant acme" \
    fleet sync repo/ifritah-api:v2 --type backend --tenant acme

expect_plan "bash scripts/backup-tenant.sh --all" \
    fleet backup

expect_plan "bash scripts/restore-tenant.sh acme --from acme_20250101_120000" \
    tenant restore acme --from acme_20250101_120000

expect_plan "bash scripts/manage-backups.sh list acme --json" \
    tenant backups list acme --json

expect_plan "bash scripts/manage-backups.sh prune --dry-run" \
    fleet backups prune --dry-run

expect_plan "bash scripts/backup-tenant.sh acme --origin user --owner alice" \
    tenant backup acme --origin user --owner alice

expect_plan "bash scripts/restart-stack.sh --env all" \
    stack restart --env all

expect_plan "bash scripts/setup-nats.sh" \
    setup nats

expect_plan "bash scripts/verify-mysql.sh" \
    db verify

expect_plan "bash scripts/discover-dokku-nginx.sh" \
    dokku discover-nginx

expect_plan "bash scripts/status.sh --json" \
    script status.sh --json

echo
echo "=== deployctl help ==="
bash scripts/deployctl.sh --help | grep -q 'tenant create' && pass "help lists tenant commands" || fail "help missing tenant commands"