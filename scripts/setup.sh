#!/usr/bin/env bash
# =============================================================================
# setup.sh — Fully interactive multi-tenant deployment setup
# =============================================================================
# Prerequisites: Docker Engine on the host. Nothing else is installed.
# This script will:
#   1. Ask all required configuration questions
#   2. Write config.env automatically
#   3. Pull Docker images (Dokku, MySQL client)
#   4. Start Dokku as a Docker container
#   5. Create master database
#   6. Set up auto-deploy (polling cron + optional webhook)
#   7. Optionally create your first tenant
#
# Usage:  sudo ./scripts/setup.sh [--config <path>]
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; }
info()  { echo -e "${BLUE}[i]${NC} $*"; }
ask()   { echo -en "${CYAN}[?]${NC} $1"; }

# Prompt with default value: prompt_val "question" "default"
prompt_val() {
    local answer
    if [ -n "${2:-}" ]; then
        ask "$1 [${2}]: "
        read -r answer
        echo "${answer:-$2}"
    else
        ask "$1: "
        read -r answer
        echo "$answer"
    fi
}

# Yes/no prompt: prompt_yn "question" "y" → returns 0 for yes, 1 for no
prompt_yn() {
    local answer default="${2:-y}"
    if [ "$default" = "y" ]; then
        ask "$1 [Y/n]: "
    else
        ask "$1 [y/N]: "
    fi
    read -r answer
    answer="${answer:-$default}"
    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG_FILE="$2"; shift 2 ;;
        *)        error "Unknown option: $1"; exit 1 ;;
    esac
done

CONFIG_FILE="${CONFIG_FILE:-$PROJECT_DIR/config.env}"

# ---- Must run as root ----
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root (sudo)."
    exit 1
fi

# ---- Check Docker ----
if ! command -v docker &>/dev/null; then
    error "Docker not found. Install Docker Engine first:"
    error "  https://docs.docker.com/engine/install/"
    exit 1
fi
log "Docker found: $(docker --version)"

# Source shared helpers (mysql/mysqldump via Docker containers)
source "$SCRIPT_DIR/lib.sh"

# In-script fallback for the `dokku` CLI: prefer calling the container directly
# to avoid "dokku: command not found" when /usr/local/bin/dokku isn't available
# (shell functions take precedence over external commands in POSIX shells).
dokku() {
    docker exec -i dokku dokku "$@"
}

# =============================================================================
# STEP 1: Interactive configuration
# =============================================================================
echo ""
echo "==========================================="
echo "  Dokku Multi-Tenant Setup"
echo "==========================================="
echo ""

NEED_CONFIG=true
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    if [ "${BASE_DOMAIN:-app.example.com}" != "app.example.com" ] && [ -n "${BASE_DOMAIN:-}" ]; then
        echo "  Existing config found: $CONFIG_FILE"
        echo "  Domain:  *.${BASE_DOMAIN}"
        echo "  MySQL:   ${MYSQL_HOST:-host.docker.internal}:${MYSQL_PORT:-3306}"
        echo ""
        if prompt_yn "Use existing config?" "y"; then
            NEED_CONFIG=false
        fi
    fi
fi

PUBLIC_PROTOCOL="${PUBLIC_PROTOCOL:-https}"

if $NEED_CONFIG; then
    echo ""
    info "I'll ask a few questions to generate your config.env."
    echo ""

    # ---- Domain ----
    BASE_DOMAIN=$(prompt_val "Your base domain (tenants become <name>.THIS)" "app.example.com")
    while [ "$BASE_DOMAIN" = "app.example.com" ] || [ -z "$BASE_DOMAIN" ]; do
        warn "Please enter your real domain."
        BASE_DOMAIN=$(prompt_val "Your base domain")
    done

    ACME_EMAIL=$(prompt_val "Email for SSL certificates" "admin@${BASE_DOMAIN%%.*}.${BASE_DOMAIN#*.}")

    # ---- Nginx mode ----
    echo ""
    info "Nginx mode: host nginx on 80/443 forwards tenant hosts to Dokku."
    NGINX_MODE="behind-nginx"
    DOKKU_PORT=$(prompt_val "Dokku internal port" "8080")
    DOKKU_HOSTNAME=$(prompt_val "Dokku hostname" "$BASE_DOMAIN")

    # ---- MySQL ----
    echo ""
    info "MySQL connection (your existing MySQL server on this machine)."
    MYSQL_HOST=$(prompt_val "MySQL host (use host.docker.internal to reach host)" "host.docker.internal")
    MYSQL_PORT=$(prompt_val "MySQL port" "3306")
    MYSQL_ADMIN_USER=$(prompt_val "MySQL deployment account" "dokku_admin")

    MYSQL_ADMIN_PASSWORD=""
    while [ -z "$MYSQL_ADMIN_PASSWORD" ] || [ "$MYSQL_ADMIN_PASSWORD" = "changeme" ]; do
        MYSQL_ADMIN_PASSWORD=$(prompt_val "MySQL deployment account password")
        if [ -z "$MYSQL_ADMIN_PASSWORD" ] || [ "$MYSQL_ADMIN_PASSWORD" = "changeme" ]; then
            warn "Please enter the password for the deployment account."
        fi
    done

    MYSQL_MASTER_DB=$(prompt_val "Master database name" "zatca_master")

    # ---- Docker Hub ----
    echo ""
    info "Docker Hub (for CI/CD — images are pushed here by GitHub Actions)."
    DOCKERHUB_USERNAME=$(prompt_val "Docker Hub username (leave empty to skip)" "")

    # ---- Message service ----
    echo ""
    MSG_HOST=""
    MSG_PORT=""
    if prompt_yn "Do you have a message service (RabbitMQ, Redis, etc.) on the host?" "n"; then
        MSG_HOST=$(prompt_val "Message service host" "host.docker.internal")
        MSG_PORT=$(prompt_val "Message service port" "5672")
    fi

    # ---- Webhook ----
    echo ""
    WEBHOOK_SECRET=""
    SETUP_WEBHOOK=false
    if [ -n "$DOCKERHUB_USERNAME" ]; then
        if prompt_yn "Set up webhook for instant deploy? (recommended with Docker Hub)" "y"; then
            SETUP_WEBHOOK=true
            WEBHOOK_SECRET=$(openssl rand -hex 32)
            info "Generated webhook secret: $WEBHOOK_SECRET"
            info "You'll need to add this as a GitHub Secret later."
        fi
    fi

    # ---- Storage ----
    STORAGE_ROOT=$(prompt_val "Tenant data directory" "/opt/tenant-data")
    BACKUP_DIR=$(prompt_val "Backup directory" "/opt/tenant-backups")
    TENANT_STATE_DIR="/opt/tenant-state"
    LOG_DIR="/opt/dashboard-logs"
    NGINX_CONF_DIR="/etc/nginx/dokku-tenants"

    # ---- Write config.env ----
    echo ""
    log "Writing config to: $CONFIG_FILE"
    cat > "$CONFIG_FILE" <<ENVFILE
# =============================================================================
# Dokku Multi-Tenant Configuration (auto-generated by setup.sh)
# =============================================================================

BASE_DOMAIN=${BASE_DOMAIN}
PUBLIC_PROTOCOL=${PUBLIC_PROTOCOL}
ACME_EMAIL=${ACME_EMAIL}
NGINX_MODE=${NGINX_MODE}
DOKKU_PORT=${DOKKU_PORT}
DOKKU_HOSTNAME=${DOKKU_HOSTNAME}
NGINX_CONF_DIR=${NGINX_CONF_DIR}
STORAGE_ROOT=${STORAGE_ROOT}
BACKUP_DIR=${BACKUP_DIR}
TENANT_STATE_DIR=${TENANT_STATE_DIR}
LOG_DIR=${LOG_DIR}

# External MySQL
MYSQL_HOST=${MYSQL_HOST}
MYSQL_PORT=${MYSQL_PORT}
MYSQL_ADMIN_USER=${MYSQL_ADMIN_USER}
MYSQL_ADMIN_PASSWORD=${MYSQL_ADMIN_PASSWORD}
MYSQL_MASTER_DB=${MYSQL_MASTER_DB}

# Docker Hub
DOCKERHUB_USERNAME=${DOCKERHUB_USERNAME}
PULL_TAG=dev
ENVFILE

    # Optional sections
    if [ -n "$MSG_HOST" ]; then
        cat >> "$CONFIG_FILE" <<ENVFILE

# Message Service
MSG_HOST=${MSG_HOST}
MSG_PORT=${MSG_PORT}
ENVFILE
    fi

    if [ -n "$WEBHOOK_SECRET" ]; then
        cat >> "$CONFIG_FILE" <<ENVFILE

# Webhook Deploy
WEBHOOK_SECRET=${WEBHOOK_SECRET}
ENVFILE
    fi

    log "Config saved."
    source "$CONFIG_FILE"
fi

# Re-read all config values with defaults
BASE_DOMAIN="${BASE_DOMAIN:?}"
PUBLIC_PROTOCOL="${PUBLIC_PROTOCOL:-https}"
ACME_EMAIL="${ACME_EMAIL:-}"
NGINX_MODE="${NGINX_MODE:-behind-nginx}"
if [ "$NGINX_MODE" = "behind-nginx-shared" ]; then
    NGINX_MODE="behind-nginx"
fi
if [ "$NGINX_MODE" != "behind-nginx" ]; then
    warn "Unsupported NGINX_MODE=${NGINX_MODE}; using behind-nginx (host nginx owns 80/443)."
    NGINX_MODE="behind-nginx"
fi
DOKKU_PORT="${DOKKU_PORT:-8080}"
DOKKU_HOSTNAME="${DOKKU_HOSTNAME:-$BASE_DOMAIN}"
NGINX_CONF_DIR="${NGINX_CONF_DIR:-/etc/nginx/dokku-tenants}"
STORAGE_ROOT="${STORAGE_ROOT:-/opt/tenant-data}"
BACKUP_DIR="${BACKUP_DIR:-/opt/tenant-backups}"
TENANT_STATE_DIR="${TENANT_STATE_DIR:-/opt/tenant-state}"
LOG_DIR="${LOG_DIR:-/opt/dashboard-logs}"
MYSQL_HOST="${MYSQL_HOST:-host.docker.internal}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
if [ -z "${MYSQL_ADMIN_USER:-}" ]; then
    if [ -n "${MYSQL_ROOT_USER:-}" ]; then
        MYSQL_ADMIN_USER="$MYSQL_ROOT_USER"
    elif [ -n "${MYSQL_ROOT_PASSWORD:-}" ] && [ -z "${MYSQL_ADMIN_PASSWORD:-}" ]; then
        MYSQL_ADMIN_USER="root"
    else
        MYSQL_ADMIN_USER="dokku_admin"
    fi
fi
MYSQL_ADMIN_PASSWORD="${MYSQL_ADMIN_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"
MYSQL_MASTER_DB="${MYSQL_MASTER_DB:-zatca_master}"
DOCKERHUB_USERNAME="${DOCKERHUB_USERNAME:-}"
WEBHOOK_SECRET="${WEBHOOK_SECRET:-}"
SETUP_WEBHOOK="${SETUP_WEBHOOK:-false}"

echo ""
echo "==========================================="
echo "  Configuration"
echo "==========================================="
echo "  Domain:     *.${BASE_DOMAIN}"
echo "  Public URL: ${PUBLIC_PROTOCOL}://${BASE_DOMAIN}"
echo "  Email:      ${ACME_EMAIL:-not set}"
echo "  Nginx:      ${NGINX_MODE}"
echo "  Dokku:      ${DOKKU_HOSTNAME}:${DOKKU_PORT}"
echo "  MySQL:      ${MYSQL_HOST}:${MYSQL_PORT}"
echo "  Docker Hub: ${DOCKERHUB_USERNAME:-not configured}"
echo "  Storage:    ${STORAGE_ROOT}"
echo "==========================================="
echo ""

# ---- Step 1: Dokku (runs as Docker container) ----
log "Pulling required Docker images..."
docker pull -q dokku/dokku:latest
if ! command -v mysql &>/dev/null; then
    log "No host mysql client found — pulling mysql:8.0 Docker image..."
    docker pull -q mysql:8.0
else
    log "Using host mysql client: $(mysql --version 2>/dev/null | head -1)"
fi

if docker ps -a --format '{{.Names}}' | grep -q '^dokku$'; then
    log "Dokku container already exists"
    CURRENT_DOKKU_PORT="$(docker inspect dokku --format '{{range $port, $bindings := .HostConfig.PortBindings}}{{if eq $port "80/tcp"}}{{range $binding := $bindings}}{{println $binding.HostPort}}{{end}}{{end}}{{end}}' 2>/dev/null || true)"
    if [ -n "$CURRENT_DOKKU_PORT" ]; then
        CURRENT_DOKKU_PORT="$(awk 'NF { print; exit }' <<<"$CURRENT_DOKKU_PORT")"
    else
        CURRENT_DOKKU_PORT="$(docker port dokku 80/tcp 2>/dev/null || true)"
        CURRENT_DOKKU_PORT="$(awk -F: 'NR == 1 { print $NF }' <<<"$CURRENT_DOKKU_PORT")"
    fi
    if [ -n "$CURRENT_DOKKU_PORT" ] && [ "$CURRENT_DOKKU_PORT" != "$DOKKU_PORT" ]; then
        error "Existing Dokku container maps host port ${CURRENT_DOKKU_PORT}->80, but config requests ${DOKKU_PORT}->80."
        error "Remove/recreate the dokku container or set DOKKU_PORT=${CURRENT_DOKKU_PORT} in $CONFIG_FILE."
        exit 1
    fi
    if ! docker ps --format '{{.Names}}' | grep -q '^dokku$'; then
        log "Starting Dokku container..."
        docker start dokku
    fi
else
    log "Creating Dokku container..."
    docker run -d \
        --name dokku \
        --restart always \
        --privileged \
        --add-host=host.docker.internal:host-gateway \
        -p "${DOKKU_PORT}":80 \
        -v /var/lib/dokku:/mnt/dokku \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -e DOKKU_HOSTNAME="${DOKKU_HOSTNAME}" \
        dokku/dokku:latest

    # Wait for Dokku to be ready
    log "Waiting for Dokku to initialize..."
    for i in $(seq 1 30); do
        if docker exec dokku dokku version &>/dev/null; then
            break
        fi
        sleep 2
    done
    log "Dokku container ready: $(docker exec dokku dokku version)"
fi

# Create 'dokku' wrapper command on the host
cat > /usr/local/bin/dokku <<'WRAPPER'
#!/bin/bash
docker exec -i dokku dokku "$@"
WRAPPER
chmod +x /usr/local/bin/dokku

# ---- Step 2: Set global domain ----
log "Setting global domain: ${BASE_DOMAIN}"
dokku domains:set-global "${BASE_DOMAIN}"

# ---- Step 3: Install plugins ----
DOKKU_PORT="${DOKKU_PORT:-8080}"
NGINX_CONF_DIR="${NGINX_CONF_DIR:-/etc/nginx/dokku-tenants}"

log "Skipping Dokku TLS plugins — TLS is handled by the operator's host nginx."

# ---- Step 5: Create storage root ----
STORAGE_ROOT="${STORAGE_ROOT:-/opt/tenant-data}"
log "Creating storage root: ${STORAGE_ROOT}"
mkdir -p "${STORAGE_ROOT}"
log "Creating backup/state/log directories"
mkdir -p "${BACKUP_DIR}" "${TENANT_STATE_DIR}" "${LOG_DIR}"

# ---- Step 5b: External MySQL — master database ----
if mysql_admin_configured; then
    log "Setting up master database: ${MYSQL_MASTER_DB}"

    run_mysql <<SQLEOF
CREATE DATABASE IF NOT EXISTS \`${MYSQL_MASTER_DB}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE \`${MYSQL_MASTER_DB}\`;
CREATE TABLE IF NOT EXISTS tenant (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    name            VARCHAR(100)  NOT NULL COMMENT 'Friendly tenant name',
    db_name         VARCHAR(100)  NOT NULL UNIQUE COMMENT 'MySQL database name for this tenant',
    zatca_env       VARCHAR(20)   NOT NULL DEFAULT 'production' COMMENT 'sandbox, simulation, or production',
    alert_email     VARCHAR(255)  NOT NULL DEFAULT '' COMMENT 'Email for failure alerts',
    enabled         TINYINT(1)    NOT NULL DEFAULT 1 COMMENT '0 = paused',
    backend_image   VARCHAR(255)  NOT NULL DEFAULT '' COMMENT 'Per-tenant override (empty = use global latest)',
    frontend_image  VARCHAR(255)  NOT NULL DEFAULT '' COMMENT 'Per-tenant override (empty = use global latest)',
    created_at      TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_enabled (enabled)
) ENGINE=InnoDB;
-- Add columns if upgrading from older schema
ALTER TABLE tenant ADD COLUMN IF NOT EXISTS backend_image  VARCHAR(255) NOT NULL DEFAULT '';
ALTER TABLE tenant ADD COLUMN IF NOT EXISTS frontend_image VARCHAR(255) NOT NULL DEFAULT '';
SQLEOF

    log "Master database ready: ${MYSQL_MASTER_DB}.tenant"
else
    warn "MYSQL_ADMIN_PASSWORD not configured. Skipping master DB setup."
    warn "Edit config.env and re-run setup.sh to create master database."
fi

# ---- Step 6: Nginx configuration ----
log "Mode: behind-nginx — host nginx proxies to Dokku on 127.0.0.1:${DOKKU_PORT}"

    # Bind Dokku's nginx to localhost only so it doesn't conflict
    dokku nginx:set --global bind-address-ipv4 "127.0.0.1"

    # Upload limit on Dokku's internal nginx
    dokku_shell "mkdir -p /home/dokku/.nginx.conf.d"
    docker exec -i dokku bash -c "cat > /home/dokku/.nginx.conf.d/upload-limit.conf" <<'NGINX'
client_max_body_size 50m;
NGINX
    dokku_shell "chown dokku:dokku /home/dokku/.nginx.conf.d/upload-limit.conf"

    # Create directory for external nginx tenant configs
    mkdir -p "$NGINX_CONF_DIR"

    # Generate upstream definition for external nginx
    cat > "$NGINX_CONF_DIR/00-dokku-upstream.conf" <<UPSTREAMCONF
# Auto-generated by Dokku multi-tenant setup
# Include this in your nginx.conf http block:
#   include ${NGINX_CONF_DIR}/*.conf;

upstream dokku_backend {
    server 127.0.0.1:${DOKKU_PORT};
}
UPSTREAMCONF

    echo ""
    warn "=== ACTION REQUIRED ==="
    warn "Add this line to your existing nginx.conf (inside the http block):"
    warn "  include ${NGINX_CONF_DIR}/*.conf;"
    warn ""
    warn "TLS is handled by YOUR host nginx. This repo does not manage certificates."
    echo ""

# ---- Step 7: Script permissions ----
chmod +x "$SCRIPT_DIR"/*.sh

# =============================================================================
# STEP 8: Auto-deploy setup (polling + optional webhook)
# =============================================================================
if [ -n "$DOCKERHUB_USERNAME" ]; then
    echo ""
    log "Setting up auto-deploy from Docker Hub..."

    # ---- 8a: Polling cron (safety net, checks every 2 min) ----
    CRON_LINE="*/2 * * * * $SCRIPT_DIR/auto-pull.sh --config $CONFIG_FILE >> /var/log/auto-pull.log 2>&1"
    if crontab -l 2>/dev/null | grep -qF "auto-pull.sh"; then
        log "Auto-pull cron already installed."
    else
        (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
        log "Auto-pull cron installed (checks Docker Hub every 2 min)."
    fi
    mkdir -p /var/lib/auto-pull

    # ---- 8c: Daily backup cron (3am) ----
    BACKUP_CRON="0 3 * * * $SCRIPT_DIR/backup-tenant.sh --all --config $CONFIG_FILE >> /var/log/tenant-backup.log 2>&1"
    if crontab -l 2>/dev/null | grep -qF "backup-tenant.sh"; then
        log "Backup cron already installed."
    else
        (crontab -l 2>/dev/null; echo "$BACKUP_CRON") | crontab -
        log "Backup cron installed (runs daily at 3am, keeps 30 days)."
    fi

    # ---- 8b: Webhook service (instant deploy) ----
    if [ -n "$WEBHOOK_SECRET" ]; then
        log "Setting up webhook service..."

        # Build the webhook container image (pre-installs deps so restarts are instant)
        docker build -t webhook-deploy:latest -f "$SCRIPT_DIR/Dockerfile.webhook" "$SCRIPT_DIR"

        # Write the systemd unit
        cp "$SCRIPT_DIR/webhook-deploy.service" /etc/systemd/system/webhook-deploy.service
        systemctl daemon-reload
        systemctl enable --now webhook-deploy 2>/dev/null || true
        log "Webhook service started on 127.0.0.1:9999 (localhost only)."

        # Set up TLS reverse proxy
        log "Setting up HTTPS proxy for the webhook..."
        "$SCRIPT_DIR/webhook-tls.sh" || warn "webhook-tls.sh failed — you can rerun it later."
    fi
else
    info "No Docker Hub username configured — skipping auto-deploy setup."
    info "You can deploy manually with: ./scripts/deploy-all.sh <image> --type backend"
fi

# =============================================================================
# STEP 9: Optionally create first tenant
# =============================================================================
echo ""
if prompt_yn "Create your first tenant now?" "y"; then
    TENANT_NAME=$(prompt_val "Tenant name (lowercase, e.g. 'acme')")
    TENANT_NAME="$(echo "$TENANT_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/^-//;s/-$//')"

    if [ -z "$TENANT_NAME" ]; then
        warn "Invalid tenant name — skipping."
    else
        TENANT_CMD="$SCRIPT_DIR/create-tenant.sh $TENANT_NAME --config $CONFIG_FILE"

        if [ -n "$DOCKERHUB_USERNAME" ]; then
            RELEASE_TAG="${APP_IMAGE_VERSION_DEFAULT:-${PULL_TAG:-dev}}"
            BACKEND_IMG="${BACKEND_IMAGE:-${DOCKERHUB_USERNAME}/ifritah-api}:${RELEASE_TAG}"
            FRONTEND_IMG="${FRONTEND_IMAGE:-${DOCKERHUB_USERNAME}/ifritah-web}:${RELEASE_TAG}"

            info "Will deploy from: $BACKEND_IMG + $FRONTEND_IMG"
            if prompt_yn "Are images already pushed to Docker Hub?" "n"; then
                TENANT_CMD="$TENANT_CMD --backend-image $BACKEND_IMG --frontend-image $FRONTEND_IMG"
            else
                info "Creating tenant without images. Deploy later:"
                info "  dokku git:from-image ${TENANT_NAME}-backend $BACKEND_IMG"
                info "  dokku git:from-image ${TENANT_NAME}-frontend $FRONTEND_IMG"
                TENANT_CMD="$TENANT_CMD --git-only"
            fi
        else
            info "No Docker Hub — tenant will be created for git push deploy."
            TENANT_CMD="$TENANT_CMD --git-only"
        fi

        echo ""
        log "Creating tenant: $TENANT_NAME"
        bash $TENANT_CMD || warn "Tenant creation had issues — check output above."
    fi
fi

# =============================================================================
# DONE
# =============================================================================
echo ""
log "==========================================="
log "  Setup complete!"
log ""
log "  DNS: Point *.${BASE_DOMAIN} → this server's IP"
log "  Dokku: running as Docker container"
log "  Config: $CONFIG_FILE"
log ""
if [ -n "$DOCKERHUB_USERNAME" ]; then
    log "  Auto-deploy: webhook/cron can pull exact VERSION tags ✓"
    if [ -n "$WEBHOOK_SECRET" ]; then
        log "  Webhook: port 9999 ✓"
        log ""
        log "  ── GitHub Secrets to add (both repos) ──"
        log "  DOCKERHUB_USERNAME = $DOCKERHUB_USERNAME"
        log "  DOCKERHUB_TOKEN    = <your Docker Hub access token>"
        log "  WEBHOOK_SECRET     = $WEBHOOK_SECRET"
        WEBHOOK_URL="$(public_url "deploy.${BASE_DOMAIN}")/deploy"
        log "  WEBHOOK_URL_DEV    = ${WEBHOOK_URL}"
        log "  WEBHOOK_URL_PROD   = ${WEBHOOK_URL}"
    fi
    log ""
    log "  ── CI workflow files ──"
    log "  Backend repo:  cp ${PROJECT_DIR}/ci/backend-deploy.yml .github/workflows/deploy.yml"
    log "  Frontend repo: cp ${PROJECT_DIR}/ci/frontend-deploy.yml .github/workflows/deploy.yml"
fi
log ""
log "  Create more tenants:"
log "    sudo ./scripts/create-tenant.sh <name> --backend-image ${BACKEND_IMAGE:-${DOCKERHUB_USERNAME:-youruser}/ifritah-api}:${APP_IMAGE_VERSION_DEFAULT:-dev} --frontend-image ${FRONTEND_IMAGE:-${DOCKERHUB_USERNAME:-youruser}/ifritah-web}:${APP_IMAGE_VERSION_DEFAULT:-dev}"
log ""
log "==========================================="
echo ""
