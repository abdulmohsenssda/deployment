#!/usr/bin/env bash
# Local test for the changes in fix/auto-ensure-dokku.
# Uses an alpine container as a stand-in for "dokku" so we can exercise
# ensure_dokku_running / restart-stack.sh without needing a real Dokku install.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

PASS() { echo "PASS: $*"; }
FAIL() { echo "FAIL: $*"; exit 1; }

echo "=== 1. bash -n on changed scripts ==="
for f in scripts/lib.sh scripts/setup-dokku.sh scripts/setup.sh scripts/restart-stack.sh scripts/create-tenant.sh scripts/init-tenant-db.sh scripts/verify-mysql.sh scripts/list-tenants.sh scripts/tail-logs.sh scripts/update-tenant.sh scripts/rollback-tenant.sh scripts/remove-tenant.sh scripts/cleanup-broken-tenant.sh scripts/backup-tenant.sh scripts/deploy-all.sh scripts/set-tenant-image.sh scripts/setup-dev-tenant.sh scripts/auto-pull.sh scripts/post-merge-cleanup.sh; do
    bash -n "$f" && PASS "syntax $f" || FAIL "syntax $f"
done

echo
echo "=== 2. setup-dokku.sh reads install.env ==="
[ -f install.env ] && cp install.env install.env.bak
trap '[ -f install.env.bak ] && mv install.env.bak install.env || rm -f install.env' EXIT
cat > install.env <<EOF
DOKKU_PORT=18082
DOKKU_HOSTNAME=test.example.com
EOF

# Inject a fake `docker` to short-circuit before any real container ops.
STUB_DIR="$(mktemp -d)"
cat > "$STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo "Docker (stub)"; exit 0; fi
if [ "$1" = "ps" ]; then exit 0; fi  # pretend no dokku container
if [ "$1" = "run" ]; then
    echo "STUB-DOCKER-RUN: $*" >&2
    exit 99   # bail out before any wait loop
fi
exit 0
STUB
chmod +x "$STUB_DIR/docker"

OUT="$(PATH="$STUB_DIR:$PATH" bash scripts/setup-dokku.sh 2>&1 || true)"
echo "$OUT" | grep -q '18082->80' && PASS "DOKKU_PORT from install.env honored" \
    || { echo "$OUT"; FAIL "expected '18082->80' in setup-dokku.sh output"; }
echo "$OUT" | grep -q -- '-p 443:443' \
    && { echo "$OUT"; FAIL "setup-dokku.sh must not publish 443"; } \
    || PASS "setup-dokku.sh does not publish 443"

echo
echo "=== 3. setup scripts do not manually reload nginx ==="
if grep -R -n -E 'sv reload /etc/service/nginx|nginx -s reload' scripts/setup-dokku.sh scripts/setup.sh; then
    FAIL "setup scripts should not manually reload nginx inside dokku"
else
    PASS "no manual nginx reload in setup scripts"
fi

echo
echo "=== 4. ensure_dokku_running prints log on failure ==="
# Source lib.sh and invoke ensure_dokku_running with stub docker that pretends
# the container exists but is stopped, and `docker start` fails.
cat > "$STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
    "ps -a")       echo dokku ;;
    "ps --format") ;; # no running containers
    "start"*)      exit 1 ;;   # simulate start failure
    "logs"*)       echo "FAKE-DOKKU-LOG: oom killed" ;;
    *)             ;;
esac
STUB
OUT="$(PATH="$STUB_DIR:$PATH" bash -c "source scripts/lib.sh; ensure_dokku_running" 2>&1 || true)"
echo "$OUT" | grep -q 'FAKE-DOKKU-LOG' && PASS "log dumped on start failure" \
    || { echo "$OUT"; FAIL "expected log dump"; }

echo
echo "=== 5. tenant backend is internal-only ==="
if grep -n 'domains:add "$BACKEND_APP" "$TENANT_DOMAIN"' scripts/create-tenant.sh; then
    FAIL "backend must not get the public tenant domain"
else
    PASS "create-tenant does not add public backend domain"
fi
grep -q 'proxy:disable "$BACKEND_APP"' scripts/create-tenant.sh \
    && PASS "create-tenant disables backend proxy" \
    || FAIL "create-tenant must disable backend proxy"
grep -q 'domains:clear "$be"' scripts/post-merge-cleanup.sh \
    && grep -q 'proxy:disable "$be"' scripts/post-merge-cleanup.sh \
    && grep -q 'API_URL="\${public_url}/api"' scripts/post-merge-cleanup.sh \
    && PASS "cleanup removes existing backend public proxy and refreshes frontend URL" \
    || FAIL "cleanup must remove existing backend public proxy"
grep -q 'BASE_DOMAIN="\${BASE_DOMAIN:?BASE_DOMAIN not set in config.env}"' scripts/update-tenant.sh \
    && grep -q 'domains:clear "\$BACKEND_APP"' scripts/update-tenant.sh \
    && grep -q 'APP_DOMAIN="\$TENANT_DOMAIN"' scripts/update-tenant.sh \
    && grep -q 'API_URL="\${PUBLIC_TENANT_URL}/api"' scripts/update-tenant.sh \
    && PASS "tenant update reconciles persisted routing values" \
    || FAIL "tenant update must reconcile persisted routing values"
grep -q 'ensure_tenant_network "$TENANT_NETWORK"' scripts/create-tenant.sh \
    && grep -q 'docker network inspect \$network' scripts/create-tenant.sh \
    && grep -q 'docker network create \$network' scripts/create-tenant.sh \
    && grep -q 'TENANT_NETWORK="${TENANT_APP_NETWORK:-web}"' scripts/create-tenant.sh \
    && grep -q 'find_existing_tenant_network' scripts/create-tenant.sh \
    && ! grep -q 'TENANT_NETWORK="tenant-${TENANT_NAME}"' scripts/create-tenant.sh \
    && ! grep -q 'network:create "\$TENANT_NETWORK" 2>/dev/null || info "Network \$TENANT_NETWORK already exists"' scripts/create-tenant.sh \
    && PASS "create-tenant uses a reusable tenant Docker network" \
    || FAIL "create-tenant must use one reusable Docker network and handle pool exhaustion"
OUT="$({
    awk '/^validate_docker_network_name\(\)/ {printing=1} /^while \[\[/ {exit} printing {print}' scripts/create-tenant.sh
    cat <<'STUB'
log() { echo "[+] $*"; }
warn() { echo "[!] $*"; }
info() { echo "[i] $*"; }
error() { echo "[x] $*" >&2; }
dokku() { [ "$1" = "network:create" ] && return 1; return 1; }
dokku_shell() {
    case "$*" in
        *"docker network inspect tenant-smoke"*) return 1 ;;
        *"docker network create tenant-smoke"*) echo "Error response from daemon: all predefined address pools have been fully subnetted" >&2; return 1 ;;
        *"docker network ls"*) echo "web"; return 0 ;;
        *"docker network inspect web"*) return 0 ;;
        *) echo "unexpected dokku_shell: $*" >&2; return 1 ;;
    esac
}
TENANT_NETWORK=tenant-smoke
ensure_tenant_network "$TENANT_NETWORK"
echo "TENANT_NETWORK=$TENANT_NETWORK"
STUB
} | bash 2>&1)"
echo "$OUT" | grep -q 'all predefined address pools have been fully subnetted' \
    && echo "$OUT" | grep -q 'TENANT_NETWORK=web' \
    && PASS "create-tenant reuses an existing tenant network when Docker pools are exhausted" \
    || { echo "$OUT"; FAIL "create-tenant must locally reproduce and handle Docker address-pool exhaustion"; }


echo
echo "=== 6. restart-stack.sh --help prints usage ==="
bash scripts/restart-stack.sh --help | grep -qi 'restart' && PASS "help works" \
    || FAIL "help missing"

echo
echo "=== 7. restart-stack.sh stops before starting ==="
if grep -q 'docker restart dokku' scripts/restart-stack.sh; then
    FAIL "restart-stack must not use docker restart dokku"
else
    PASS "restart-stack avoids docker restart"
fi
grep -q 'docker compose -f "$compose_file" down --remove-orphans' scripts/restart-stack.sh \
    && PASS "dashboard compose is stopped before start" \
    || FAIL "dashboard compose down is required"
grep -q 'docker stop --time "$DOKKU_STOP_SECONDS" dokku' scripts/restart-stack.sh \
    && PASS "dokku stop has explicit timeout" \
    || FAIL "dokku stop must use an explicit timeout"
grep -q 'docker kill dokku' scripts/restart-stack.sh \
    && PASS "dokku stop has kill fallback" \
    || FAIL "dokku stop must have a kill fallback"
grep -q 'dokku stopped' scripts/restart-stack.sh \
    && PASS "dokku stop prints completion" \
    || FAIL "dokku stop must print a completion line"
grep -q 'dokku_https_port' scripts/restart-stack.sh \
    && grep -q 'old unsupported 443 publish' scripts/restart-stack.sh \
    && PASS "old 443 publish triggers dokku recreate" \
    || FAIL "restart-stack must recreate old 443-published dokku containers"
grep -q 'docker compose -f "$compose_file" down --remove-orphans' scripts/restart-stack.sh \
    && grep -q 'run_with_timeout "$COMMAND_TIMEOUT_SECONDS"' scripts/restart-stack.sh \
    && PASS "dashboard compose down is bounded" \
    || FAIL "dashboard compose down must be bounded"

echo
echo "=== 8. restart-stack.sh accepts --env all ==="
bash scripts/restart-stack.sh --help | grep -q -- '--env all' \
    && PASS "help documents --env all" \
    || FAIL "help must document --env all"

echo
echo "=== 9. restart-stack.sh rejects unknown env ==="
OUT="$(bash scripts/restart-stack.sh --env staging 2>&1 || true)"
echo "$OUT" | grep -q "must be 'dev', 'prod', or 'all'" \
    && PASS "rejects unknown env" \
    || { echo "$OUT"; FAIL "should reject --env staging"; }

echo
echo "=== 10. stopped dokku with unavailable docker port is restarted ==="
STATE_FILE="$STUB_DIR/dokku-state"
echo stopped > "$STATE_FILE"
cat > "$STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
state_file="${STATE_FILE:?}"
state="$(cat "$state_file" 2>/dev/null || echo absent)"

case "$1" in
    --version)
        echo "Docker (stub)"; exit 0 ;;
    ps)
        if [[ "$*" == *"--filter name=dokku"* ]]; then
            [ "$state" = running ] && echo -e "CONTAINER:\tdokku\tSTATUS:\tUp\tPORTS:\t127.0.0.1:18082->80/tcp"
            exit 0
        fi
        if [[ "$*" == *"--format {{.Names}}"* || "$*" == *"--format '{{.Names}}'"* ]]; then
            if [[ "$*" == *"-a"* ]]; then
                [ "$state" != absent ] && echo dokku
            else
                [ "$state" = running ] && echo dokku
            fi
            exit 0
        fi
        exit 0 ;;
    port)
        if [ "$state" = stopped ]; then
            exit 1
        fi
        [ "$2" = dokku ] && [ "$3" = "80/tcp" ] && [ "$state" = running ] && echo "0.0.0.0:18082"
        exit 0 ;;
    rm)
        [ "$2" = dokku ] && echo absent > "$state_file"
        exit 0 ;;
    run)
        echo running > "$state_file"
        echo fake-dokku-id
        exit 0 ;;
    exec)
        if [ "$2" = dokku ] && [ "$3" = dokku ] && [ "$4" = version ]; then
            echo "dokku version stub"
        fi
        exit 0 ;;
    logs)
        echo "stub dokku logs"
        exit 0 ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/docker"
OUT="$(STATE_FILE="$STATE_FILE" PATH="$STUB_DIR:$PATH" bash scripts/restart-stack.sh --env dev --dokku-only 2>&1 || true)"
echo "$OUT" | grep -q 'Dokku container already stopped' \
    && echo "$OUT" | grep -q 'Recreating Dokku container: missing' \
    && echo "$OUT" | grep -q 'dokku ready: dokku version stub' \
    && PASS "stopped dokku no longer exits during docker port probe" \
    || { echo "$OUT"; FAIL "stopped dokku should recreate/start even when docker port exits non-zero"; }

echo
echo "=== 11. stopped dokku with inspectable port is started, not recreated ==="
echo stopped > "$STATE_FILE"
cat > "$STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
state_file="${STATE_FILE:?}"
state="$(cat "$state_file" 2>/dev/null || echo absent)"

case "$1" in
    ps)
        if [[ "$*" == *"--format {{.Names}}"* || "$*" == *"--format '{{.Names}}'"* ]]; then
            if [[ "$*" == *"-a"* ]]; then
                [ "$state" != absent ] && echo dokku
            else
                [ "$state" = running ] && echo dokku
            fi
        fi
        exit 0 ;;
    inspect)
        if [[ "$*" == *"80/tcp"* ]]; then
            echo 18082
        fi
        exit 0 ;;
    port)
        exit 1 ;;
    start)
        [ "$2" = dokku ] && echo running > "$state_file"
        exit 0 ;;
    exec)
        if [ "$2" = dokku ] && [ "$3" = dokku ] && [ "$4" = version ]; then
            echo "dokku version stub"
        fi
        exit 0 ;;
    logs)
        echo "stub dokku logs"
        exit 0 ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/docker"
OUT="$(STATE_FILE="$STATE_FILE" PATH="$STUB_DIR:$PATH" bash scripts/restart-stack.sh --env dev --dokku-only 2>&1 || true)"
echo "$OUT" | grep -q 'Dokku container already stopped' \
    && echo "$OUT" | grep -q 'Starting Dokku container' \
    && echo "$OUT" | grep -q 'dokku ready: dokku version stub' \
    && ! echo "$OUT" | grep -q 'Recreating Dokku container' \
    && PASS "stopped dokku with correct port starts without recreate" \
    || { echo "$OUT"; FAIL "stopped dokku with inspectable correct port should start without recreate"; }

echo
echo "=== 12. tenant DB initializer is wired ==="
if [ -e scripts/sql ]; then
    FAIL "deployment repo must not bundle backend schema/migrations"
else
    PASS "deployment repo does not bundle backend schema/migrations"
fi
grep -q -- '--backend-image' scripts/init-tenant-db.sh \
    && grep -q 'docker run --rm --entrypoint sh "\$image"' scripts/init-tenant-db.sh \
    && PASS "init-tenant-db reads schema from backend image" \
    || FAIL "init-tenant-db must stream schema/migrations from backend image"
grep -q 'TENANT_IMAGE_PULL_POLICY="${TENANT_IMAGE_PULL_POLICY:-always}"' scripts/init-tenant-db.sh \
    && grep -q 'docker pull "\$image"' scripts/init-tenant-db.sh \
    && PASS "init-tenant-db refreshes backend image before schema read" \
    || FAIL "init-tenant-db must pull backend image before reading schema"
grep -q '| run_tenant_mysql "\$TENANT_DB_NAME"' scripts/init-tenant-db.sh \
    && ! grep -q '| run_mysql "\$TENANT_DB_NAME"' scripts/init-tenant-db.sh \
    && PASS "init-tenant-db imports default schema paths as tenant DB user" \
    || FAIL "init-tenant-db must import default schema paths as tenant DB user"
if grep -q 'TENANT_ADMIN_MIGRATION_FILES\|migration_requires_admin\|apply_image_sql_file_as_admin\|verify_admin_trigger_privilege' scripts/init-tenant-db.sh; then
    FAIL "init-tenant-db must not special-case privileged trigger migrations"
else
    PASS "init-tenant-db applies migrations as tenant DB user only"
fi
if grep -R -n -E 'log_bin_trust_function_creators|GRANT[[:space:]]+SUPER' scripts/init-tenant-db.sh scripts/create-tenant.sh; then
    FAIL "tenant trigger fix must not enable log_bin_trust_function_creators or grant SUPER"
else
    PASS "tenant trigger fix avoids unsafe binlog trust and SUPER grants"
fi
if grep -R -n 'SET_USER_ID' install.env.example REQUIREMENTS.md scripts/init-tenant-db.sh scripts/verify-mysql.sh; then
    FAIL "deployment must not require global SET_USER_ID when backend migrations avoid triggers"
else
    PASS "deployment no longer requires SET_USER_ID"
fi
grep -q 'validate_tenant_schema' scripts/init-tenant-db.sh \
    && grep -q 'tenant_missing_required_tables' scripts/init-tenant-db.sh \
    && PASS "init-tenant-db verifies required base schema tables" \
    || FAIL "init-tenant-db must verify required base schema tables"
grep -q 'TENANT_IGNORED_SCHEMA_FILES="${TENANT_IGNORED_SCHEMA_FILES:-car_part.sql}"' scripts/init-tenant-db.sh \
    && grep -q 'schema_file_is_ignored' scripts/init-tenant-db.sh \
    && PASS "init-tenant-db ignores car_part schema" \
    || FAIL "init-tenant-db must ignore car_part schema"
grep -q 'IMAGE_PULL_POLICY="${IMAGE_PULL_POLICY:-always}"' scripts/deploy-all.sh \
    && grep -q 'docker pull "\$image"' scripts/deploy-all.sh \
    && grep -q 'dokku_git_from_image "\$app" "\$image"' scripts/deploy-all.sh \
    && grep -q 'No changes detected' scripts/lib.sh \
    && PASS "deploy-all refreshes image and rebuilds same-ref deploys" \
    || FAIL "deploy-all must pull image and handle same-ref git:from-image deploys"
grep -q 'init-tenant-db.sh" "\$TENANT_NAME"' scripts/create-tenant.sh \
    && grep -q -- '--backend-image "\$BACKEND_IMAGE"' scripts/create-tenant.sh \
    && grep -q -- '--env "DB_USER=\$TENANT_DB_USER"' scripts/create-tenant.sh \
    && grep -q 'init-tenant-db.sh" "\${seed_args\[@\]}"' scripts/create-tenant.sh \
    && PASS "create-tenant applies schema and seed phases" \
    || FAIL "create-tenant must call init-tenant-db.sh for schema and seed phases"
grep -q 'Name: "init-tenant-db.sh"' dashboard/internal/scripts/scripts.go \
    && grep -q 'Flag: "--backend-image"' dashboard/internal/scripts/scripts.go \
    && PASS "dashboard exposes init-tenant-db.sh" \
    || FAIL "dashboard catalog must expose init-tenant-db.sh"
for f in scripts/list-tenants.sh scripts/tail-logs.sh scripts/update-tenant.sh scripts/rollback-tenant.sh; do
    grep -q 'source "\$SCRIPT_DIR/lib.sh"' "$f" \
        && PASS "$f uses shared dokku wrapper" \
        || FAIL "$f must source lib.sh before calling dokku"
done
if grep -q 'MIGRATE_CMD=atlas' config.env.example; then
    FAIL "config example must not point to an unavailable Atlas command"
else
    PASS "config example leaves backend MIGRATE_CMD empty"
fi
grep -q 'TENANT_SCHEMA_IMAGE_PATH=' config.env.example \
    && grep -q 'TENANT_MIGRATIONS_IMAGE_DIR=' config.env.example \
    && PASS "config example points at backend image schema paths" \
    || FAIL "config example must document backend image schema paths"

echo
echo "=== 13. tenant prefixes isolate shared dev/prod targets ==="
OUT="$(TENANT_NAME_PREFIX=dev bash -c 'source scripts/lib.sh; tenant_full_name acme; echo; tenant_full_name dev-acme; echo; tenant_in_scope dev-acme && echo scoped; tenant_in_scope prod-acme || echo isolated; TENANT_NAME_PREFIX=---; [ -z "$(tenant_name_prefix)" ] && echo empty-prefix; TENANT_NAME_PREFIX=prod; TENANT_NAME_PREFIX_OVERRIDE=dev; printf override:; tenant_full_name acme; echo')"
echo "$OUT" | grep -q '^dev-acme$' \
    && [ "$(echo "$OUT" | grep -c '^dev-acme$')" -eq 2 ] \
    && echo "$OUT" | grep -q '^scoped$' \
    && echo "$OUT" | grep -q '^isolated$' \
    && echo "$OUT" | grep -q '^empty-prefix$' \
    && echo "$OUT" | grep -q '^override:dev-acme$' \
    && PASS "tenant prefix helper prefixes once and filters other environments" \
    || { echo "$OUT"; FAIL "tenant prefix helper must prefix once and isolate scopes"; }
for f in scripts/create-tenant.sh scripts/init-tenant-db.sh scripts/update-tenant.sh scripts/remove-tenant.sh scripts/cleanup-broken-tenant.sh scripts/setup-dev-tenant.sh scripts/auto-pull.sh scripts/backup-tenant.sh scripts/set-tenant-image.sh; do
    grep -q 'tenant_full_name' "$f" \
        && PASS "$f applies tenant_full_name" \
        || FAIL "$f must apply TENANT_NAME_PREFIX to explicit tenant names"
done
for f in scripts/deploy-all.sh scripts/rollback-tenant.sh scripts/list-tenants.sh scripts/status.sh scripts/tail-logs.sh scripts/backup-tenant.sh scripts/set-tenant-image.sh; do
    grep -q 'tenant_in_scope\|tenant_name_prefix' "$f" \
        && PASS "$f scopes bulk/list operations" \
        || FAIL "$f must scope bulk/list operations by TENANT_NAME_PREFIX"
done
grep -q 'TENANT_NAME_PREFIX=' dashboard/internal/scripts/scripts.go \
    && grep -q 'filterAppNames' dashboard/internal/web/web.go \
    && grep -q 'TENANT_NAME_PREFIX' dashboard/README.md \
    && PASS "dashboard passes, filters, and documents tenant prefix" \
    || FAIL "dashboard must pass/filter/document TENANT_NAME_PREFIX"

echo
echo "ALL TESTS PASSED"
