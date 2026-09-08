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

send_response() {
    local status="$1" body="$2"
    printf 'HTTP/1.1 %s\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
        "$status" "${#body}" "$body"
}

CONFIG_FILE="$PROJECT_DIR/config.env"
WEBHOOK_PORT=9999
LOG_FILE="${WEBHOOK_LOG_FILE:-/var/log/webhook-deploy.log}"

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
if [ "${WEBHOOK_SERVER_TEST_MODE:-0}" != "1" ] && ! command -v ncat &>/dev/null; then
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
        send_response "401 Unauthorized" '{"error":"unauthorized"}'
        return
    fi

    # ---- Check it's a POST to /deploy ----
    local method path
    method=$(echo "$request" | head -1 | awk '{print $1}')
    path=$(echo "$request" | head -1 | awk '{print $2}')

    if [ "$method" != "POST" ] || [ "$path" != "/deploy" ]; then
        send_response "404 Not Found" '{"error":"not found"}'
        return
    fi

    # ---- Parse JSON body (minimal — extract type and image) ----
    local app_type image tenant
    app_type=$(echo "$body" | grep -o '"type" *: *"[^"]*"' | cut -d'"' -f4 || echo "backend")
    image=$(echo "$body" | grep -o '"image" *: *"[^"]*"' | cut -d'"' -f4 || echo "")
    tenant=$(echo "$body" | grep -o '"tenant" *: *"[^"]*"' | cut -d'"' -f4 || echo "")

    if [ -z "$image" ]; then
        send_response "400 Bad Request" '{"error":"image required"}'
        return
    fi

    case "$app_type" in
        backend|frontend) ;;
        *)
            send_response "400 Bad Request" '{"error":"type must be backend or frontend"}'
            return
            ;;
    esac

    if [ -n "$tenant" ]; then
        if ! tenant="$(tenant_full_name "$tenant")"; then
            send_response "400 Bad Request" '{"error":"invalid tenant"}'
            return
        fi
    fi

    local img_name="$image" img_tag="latest" digest
    if [[ "$image" == *@* ]]; then
        img_name="${image%@*}"
        img_tag="${image#*@}"
    elif [[ "$image" == *:* ]]; then
        img_name="${image%:*}"
        img_tag="${image##*:}"
    fi

    local lock_file="${AUTO_PULL_LOCK_FILE:-$(auto_pull_state_dir)/auto-pull.lock}"
    if ! mkdir -p "$(auto_pull_state_dir)" || ! { exec 8>"$lock_file"; }; then
        send_response "500 Internal Server Error" '{"error":"reconciliation state directory is unavailable"}'
        return
    fi
    if ! flock -n 8; then
        exec 8>&-
        send_response "409 Conflict" '{"error":"another reconciliation is in progress; retry"}'
        return
    fi

    if ! digest=$(get_remote_digest "$img_name" "$img_tag"); then
        flock -u 8
        exec 8>&-
        warn "Webhook could not resolve digest for $image"
        send_response "502 Bad Gateway" '{"error":"digest lookup failed; deployment was not attempted"}'
        return
    fi

    local current_digest=""
    if [ -n "$tenant" ]; then
        current_digest="$(auto_pull_digest_read_for_tenant "$app_type" "$img_tag" "$tenant" \
            "$(auto_pull_state_dir)" || true)"
    else
        current_digest="$(auto_pull_digest_read "$app_type" "$img_tag" "$(auto_pull_state_dir)" || true)"
    fi
    if [ "$current_digest" = "$digest" ]; then
        flock -u 8
        exec 8>&-
        log "Webhook already reconciled: $image ($app_type) tenant=${tenant:-all}"
        send_response "200 OK" '{"status":"already-reconciled","digest":"'"$digest"'"}'
        return
    fi

    log "Deploy triggered: type=$app_type image=$image digest=$digest tenant=${tenant:-all}"
    local -a deploy_args=("$image" --type "$app_type")
    [ -n "$tenant" ] && deploy_args+=(--tenant "$tenant")

    local output
    if output=$("${WEBHOOK_DEPLOY_SCRIPT:-$SCRIPT_DIR/deploy-all.sh}" "${deploy_args[@]}" 2>&1); then
        printf '%s\n' "$output" >> "$LOG_FILE"
        if [ -n "$tenant" ]; then
            if ! auto_pull_digest_write_for_tenant "$app_type" "$img_tag" "$tenant" \
                    "$digest" "$img_name" "$(auto_pull_state_dir)"; then
                flock -u 8
                exec 8>&-
                warn "Deploy succeeded but digest state could not be persisted for $image"
                send_response "500 Internal Server Error" '{"error":"deployment succeeded but reconciliation state was not saved"}'
                return
            fi
        else
            if ! auto_pull_digest_write "$app_type" "$img_tag" "$digest" "$img_name"; then
                flock -u 8
                exec 8>&-
                warn "Deploy succeeded but digest state could not be persisted for $image"
                send_response "500 Internal Server Error" '{"error":"deployment succeeded but reconciliation state was not saved"}'
                return
            fi
        fi
        flock -u 8
        exec 8>&-
        log "Deploy succeeded: $image ($app_type)"
        send_response "200 OK" '{"status":"deployed","digest":"'"$digest"'"}'
    else
        printf '%s\n' "$output" >> "$LOG_FILE"
        flock -u 8
        exec 8>&-
        warn "Deploy failed: $image ($app_type)"
        send_response "502 Bad Gateway" '{"error":"deployment failed; retryable"}'
    fi
}

# Bind address — default localhost only (so HTTPS proxy must front it).
# Set WEBHOOK_BIND=0.0.0.0 in config.env to expose directly (NOT recommended).
WEBHOOK_BIND="${WEBHOOK_BIND:-127.0.0.1}"

# ---- Main loop — listen forever ----
if [ "${WEBHOOK_SERVER_TEST_MODE:-0}" != "1" ]; then
    while true; do
        handle_request < <(ncat -l "$WEBHOOK_BIND" "$WEBHOOK_PORT" --recv-only -w 30 2>/dev/null) 2>/dev/null || true
    done
fi
