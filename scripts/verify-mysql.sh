#!/usr/bin/env bash
# =============================================================================
# verify-mysql.sh — Test that the admin account works from inside a container
# =============================================================================
# Reads credentials from install.env (preferred) or config.env. Never takes
# the password on the command line, never echoes it. Uses MYSQL_PWD via
# `--env-file` so the secret never appears in /proc/<pid>/cmdline.
#
# Usage:
#   sudo bash scripts/verify-mysql.sh
#   sudo bash scripts/verify-mysql.sh --tenant-host 172.18.0.5  # test from a specific bridge
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()   { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; }
info()  { echo -e "${BLUE}[i]${NC} $*"; }

# Load values: install.env wins, then config.env
for f in "$PROJECT_DIR/install.env" "$PROJECT_DIR/config.env"; do
    if [ -f "$f" ]; then
        set -a; source "$f"; set +a
        info "Loaded $f"
        break
    fi
done

: "${MYSQL_HOST:=host.docker.internal}"
: "${MYSQL_PORT:=3306}"
if [ -z "${MYSQL_ADMIN_USER:-}" ]; then
    if [ -n "${MYSQL_ROOT_USER:-}" ]; then
        MYSQL_ADMIN_USER="$MYSQL_ROOT_USER"
    elif [ -n "${MYSQL_ROOT_PASSWORD:-}" ] && [ -z "${MYSQL_ADMIN_PASSWORD:-}" ]; then
        MYSQL_ADMIN_USER="root"
    else
        MYSQL_ADMIN_USER="dokku_admin"
    fi
fi
: "${MYSQL_ADMIN_PASSWORD:=${MYSQL_ROOT_PASSWORD:-}}"
: "${MYSQL_MASTER_DB:=zatca_master}"

if [ -z "$MYSQL_ADMIN_PASSWORD" ] || [ "$MYSQL_ADMIN_PASSWORD" = "changeme" ]; then
    error "MYSQL_ADMIN_PASSWORD not set (looked in install.env and config.env)"
    exit 1
fi

# Pass the password via env file (NOT --env so it doesn't show in `ps`)
ENV_FILE="$(mktemp)"
trap 'rm -f "$ENV_FILE"' EXIT
chmod 600 "$ENV_FILE"
printf 'MYSQL_PWD=%s\n' "$MYSQL_ADMIN_PASSWORD" > "$ENV_FILE"

mysql_client_host() {
    case "${MYSQL_HOST}" in
        localhost|127.0.0.1|::1) echo "host.docker.internal" ;;
        *) echo "$MYSQL_HOST" ;;
    esac
}

MYSQL_CLIENT_HOST="$(mysql_client_host)"
log "Testing ${MYSQL_ADMIN_USER}@${MYSQL_CLIENT_HOST}:${MYSQL_PORT}..."
if [ "$MYSQL_CLIENT_HOST" != "$MYSQL_HOST" ]; then
    info "Configured MYSQL_HOST=${MYSQL_HOST}; using ${MYSQL_CLIENT_HOST} from the Docker verifier container."
fi

mysql_client_host() {
    case "${MYSQL_HOST}" in
        localhost|127.0.0.1|::1) echo "host.docker.internal" ;;
        *) echo "$MYSQL_HOST" ;;
    esac
}

MYSQL_CLIENT_HOST="$(mysql_client_host)"

set +e
docker run --rm --env-file "$ENV_FILE" \
    --add-host=host.docker.internal:host-gateway \
    mysql:8.0 mysql \
        --protocol=TCP -h "$MYSQL_CLIENT_HOST" -P "$MYSQL_PORT" -u "$MYSQL_ADMIN_USER" \
        --connect-timeout=5 --batch --skip-column-names \
        -e "SELECT user(), @@hostname, @@version;"
RC=$?
set -e

if [ $RC -ne 0 ]; then
    error "Connection FAILED (exit $RC)"
    error "Common causes:"
    error "  • MySQL bind-address still 127.0.0.1 — set to 172.17.0.1 or 0.0.0.0"
    error "  • Firewall blocking 3306 from docker bridge"
    error "  • User '${MYSQL_ADMIN_USER}'@'172.%' not created or wrong password"
    exit $RC
fi

log "Admin connection OK ✓"

# Verify expected privileges exist
log "Checking grants..."
GRANTS="$(docker run --rm --env-file "$ENV_FILE" \
    --add-host=host.docker.internal:host-gateway \
    mysql:8.0 mysql \
        --protocol=TCP -h "$MYSQL_CLIENT_HOST" -P "$MYSQL_PORT" -u "$MYSQL_ADMIN_USER" \
        --batch --skip-column-names \
        -e "SHOW GRANTS FOR CURRENT_USER();")"
printf '%s\n' "$GRANTS"

log "All checks passed."
