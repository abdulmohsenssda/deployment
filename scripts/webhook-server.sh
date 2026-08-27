#!/usr/bin/env bash
# =============================================================================
# webhook-server.sh — Lightweight webhook listener for auto-deploy
# =============================================================================
# Listens for HTTP POST requests from GitHub Actions (or anything) and triggers
# a redeploy. No SSH keys shared — GitHub just hits a URL.
#
# Security: requests must include a secret token in the Authorization header.
#
# Usage:
#   sudo ./scripts/webhook-server.sh                    # start on port 9999
#   sudo ./scripts/webhook-server.sh --port 8888
#   sudo ./scripts/webhook-server.sh --config config.dev.env
#
# Install as systemd service:
#   sudo cp /opt/deployment/scripts/webhook-deploy.service /etc/systemd/system/
#   sudo systemctl daemon-reload
#   sudo systemctl enable --now webhook-deploy
#
# GitHub Actions calls:
#   curl -sf -X POST https://dev.yourdomain.com:9999/deploy \
#     -H "Authorization: Bearer YOUR_WEBHOOK_SECRET" \
#     -H "Content-Type: application/json" \
#     -d '{"type":"backend","image":"youruser/ifritah-api:abc123"}'
#
# Dependencies: ncat — runs automatically via Docker (see webhook-deploy.service)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib.sh"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${GREEN}[+]${NC} $*"; }
warn()  { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${YELLOW}[!]${NC} $*"; }
error() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${RED}[✗]${NC} $*"; }
info()  { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${BLUE}[i]${NC} $*"; }

CONFIG_FILE="$PROJECT_DIR/config.env"
WEBHOOK_PORT=9999
LOG_FILE="/var/log/webhook-deploy.log"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)   WEBHOOK_PORT="$2"; shift 2 ;;
        --config) CONFIG_FILE="$2"; shift 2 ;;
        -*)       echo "Unknown option: $1"; exit 1 ;;
        *)        shift ;;
    esac
done

[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

WEBHOOK_SECRET="${WEBHOOK_SECRET:-}"

if [ -z "$WEBHOOK_SECRET" ]; then
    error "WEBHOOK_SECRET not set in config.env"
    error "Add:  WEBHOOK_SECRET=\$(openssl rand -hex 32)"
    error "Then set the same value as a GitHub secret."
    exit 1
fi

# Check ncat is available (when running directly; Docker service provides it)
if ! command -v ncat &>/dev/null; then
    error "ncat not found. Use the Docker-based systemd service instead:"
    error "  sudo cp scripts/webhook-deploy.service /etc/systemd/system/"
    error "  sudo systemctl enable --now webhook-deploy"
    exit 1
fi

log "Webhook server starting on port $WEBHOOK_PORT"
info "Waiting for POST /deploy requests..."

# ---- Handle a single request ----
handle_request() {
    local request=""
    local content_length=0
    local auth_header=""
    local body=""

    # Read HTTP request headers
    while IFS= read -r line; do
        line="${line%%$'\r'}"
        [ -z "$line" ] && break
        request="$request$line"$'\n'

        # Extract content-length
        if [[ "${line,,}" == content-length:* ]]; then
            content_length=$(echo "$line" | awk '{print $2}' | tr -d '\r')
        fi

        # Extract authorization
        if [[ "${line,,}" == authorization:* ]]; then
            auth_header=$(echo "$line" | sed 's/[Aa]uthorization: *[Bb]earer *//')
        fi
    done

    # Read body
    content_length="${content_length:-0}"
    if [ "$content_length" -gt 0 ] 2>/dev/null; then
        body=$(head -c "$content_length")
    fi

    # ---- Validate auth ----
    if [ "$auth_header" != "$WEBHOOK_SECRET" ]; then
        warn "Unauthorized request (bad token)"
        echo -ne "HTTP/1.1 401 Unauthorized\r\nContent-Length: 24\r\nConnection: close\r\n\r\n{\"error\":\"unauthorized\"}"
        return
    fi

    # ---- Check it's a POST to /deploy ----
    local method path
    method=$(echo "$request" | head -1 | awk '{print $1}')
    path=$(echo "$request" | head -1 | awk '{print $2}')

    if [ "$method" != "POST" ] || [ "$path" != "/deploy" ]; then
        echo -ne "HTTP/1.1 404 Not Found\r\nContent-Length: 21\r\nConnection: close\r\n\r\n{\"error\":\"not found\"}"
        return
    fi

    # ---- Parse JSON body (minimal — extract type and image) ----
    local app_type image tenant_flag
    app_type=$(echo "$body" | grep -o '"type" *: *"[^"]*"' | cut -d'"' -f4 || echo "backend")
    image=$(echo "$body" | grep -o '"image" *: *"[^"]*"' | cut -d'"' -f4 || echo "")
    local tenant
    tenant=$(echo "$body" | grep -o '"tenant" *: *"[^"]*"' | cut -d'"' -f4 || echo "")

    if [ -z "$image" ]; then
        echo -ne "HTTP/1.1 400 Bad Request\r\nContent-Length: 26\r\nConnection: close\r\n\r\n{\"error\":\"image required\"}"
        return
    fi

    log "Deploy triggered: type=$app_type image=$image tenant=${tenant:-all}"

    # Respond immediately (deploy runs async)
    echo -ne "HTTP/1.1 200 OK\r\nContent-Length: 15\r\nConnection: close\r\n\r\n{\"status\":\"ok\"}"

    # Build command
    tenant_flag=""
    if [ -n "$tenant" ]; then
        tenant_flag="--tenant $tenant"
    fi

    # Run deploy in background and update digest so auto-pull.sh doesn't re-deploy
    (
        if "$SCRIPT_DIR/deploy-all.sh" "$image" --type "$app_type" $tenant_flag \
            >> "$LOG_FILE" 2>&1; then
            log "Deploy succeeded: $image ($app_type)" >> "$LOG_FILE" 2>&1

            # Update auto-pull digest so poller doesn't re-deploy the same image
            local digest_dir="/var/lib/auto-pull"
            mkdir -p "$digest_dir"
            local img_name="${image%%:*}"
            local img_tag="${image#*:}"
            [ "$img_tag" = "$img_name" ] && img_tag="latest"
            local digest
            digest=$(get_remote_digest "$img_name" "$img_tag" 2>/dev/null || echo "")
            if [ -n "$digest" ]; then
                echo "$digest" > "${digest_dir}/${app_type}.digest"
            fi
        else
            warn "Deploy failed: $image ($app_type)" >> "$LOG_FILE" 2>&1
        fi
    ) &
}

# Bind address — default localhost only (so HTTPS proxy must front it).
# Set WEBHOOK_BIND=0.0.0.0 in config.env to expose directly (NOT recommended).
WEBHOOK_BIND="${WEBHOOK_BIND:-127.0.0.1}"

# ---- Main loop — listen forever ----
while true; do
    handle_request < <(ncat -l "$WEBHOOK_BIND" "$WEBHOOK_PORT" --recv-only -w 30 2>/dev/null) 2>/dev/null || true
done
