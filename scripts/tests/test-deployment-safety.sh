#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }
syntax() {
    tr -d '\r' < "$1" | bash -n
}
grep_or_fail() {
    local pattern="$1" file="$2" message="$3"
    grep -qE "$pattern" "$file" || fail "$message"
}

echo "=== changed scripts parse ==="
for script in scripts/lib.sh scripts/tenant-provenance.sh \
    scripts/update-tenant.sh scripts/deploy-all.sh scripts/create-tenant.sh; do
    syntax "$script" || fail "syntax $script"
    pass "syntax $script"
done

echo
echo "=== verified DB backup is required and corruption is rejected ==="
TEST_DIR="$REPO_DIR/.test-deployment-safety.$$"
BACKUP_DIR="$TEST_DIR/backups"
mkdir -p "$BACKUP_DIR"
trap 'rm -rf "$TEST_DIR"' EXIT
printf 'CREATE TABLE safe (id INT);\n' | gzip > "$BACKUP_DIR/acme_mysql_20990101_000000.sql.gz"
{
    printf '%s\n' '{'
    printf '  "id": "acme_20990101_000000",\n'
    printf '  "tenant": "acme",\n'
    printf '  "db_artifact": "acme_mysql_20990101_000000.sql.gz",\n'
    printf '  "verified": true\n'
    printf '%s\n' '}'
} > "$BACKUP_DIR/acme_20990101_000000.meta.json"
backup="$(source <(tr -d '\r' < scripts/lib.sh); verified_tenant_db_backup acme "$BACKUP_DIR")"
printf '%s' "$backup" | grep -q 'acme_20990101_000000' || fail "verified DB backup was not found"
pass "verified DB backup is selected"
printf 'corrupt' > "$BACKUP_DIR/acme_mysql_20990101_000000.sql.gz"
if source <(tr -d '\r' < scripts/lib.sh); verified_tenant_db_backup acme "$BACKUP_DIR" >/dev/null; then
    fail "corrupt DB backup was accepted"
fi
pass "corrupt DB backup is rejected"

echo
echo "=== migration and rollback safety guards ==="
grep_or_fail 'create_verified_tenant_db_backup' scripts/update-tenant.sh \
    "update path does not create a verified backup"
grep_or_fail 'migration replay failed' scripts/update-tenant.sh \
    "migration failure is not recorded"
grep_or_fail 'MIGRATIONS_APPLIED' scripts/update-tenant.sh \
    "migration state is not tracked"
grep_or_fail 'backup_db_artifact' scripts/tenant-provenance.sh \
    "backup identity is not part of deployment audit"
grep_or_fail 'automatic image rollback refused' scripts/update-tenant.sh \
    "unsafe rollback is not refused"
grep_or_fail 'tenant is degraded' scripts/update-tenant.sh \
    "partial swap is not reported as degraded"
pass "backup, migration failure, partial swap, and rollback guards present"

echo
echo "=== create-tenant provenance gates ==="
grep_or_fail 'resolve_build_identity' scripts/create-tenant.sh \
    "create-tenant does not validate OCI labels"
grep_or_fail 'provenance_repo_digest' scripts/tenant-provenance.sh \
    "digest resolution helper is missing"
grep_or_fail 'verify_runtime_identity' scripts/create-tenant.sh \
    "create-tenant does not verify runtime identity"
grep_or_fail 'missing or inconsistent OCI BuildIdentity labels' scripts/create-tenant.sh \
    "create-tenant missing-label failure is not explicit"
pass "create-tenant rejects missing labels/digests and verifies /version"

echo
echo "=== last-known-good and rollback failure reporting ==="
grep_or_fail 'tenant_record_identity.*old_ref' scripts/update-tenant.sh \
    "last-known-good identity is not restored on safe rollback"
grep_or_fail 'rollback refused: database migrations applied' scripts/update-tenant.sh \
    "rollback failure is not persisted"
grep_or_fail 'skip-migrations.*non-production override' scripts/update-tenant.sh \
    "skip-migrations override is not audited"
pass "last-known-good preservation and rollback failure reporting present"

echo
echo "ALL DEPLOYMENT SAFETY TESTS PASSED"
