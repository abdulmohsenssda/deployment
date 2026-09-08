#!/usr/bin/env bash
# =============================================================================
# prod-up.sh — Pull the latest dashboard image and restart the container.
#
# Pulls the pre-built image from Docker Hub (built automatically by GitHub
# Actions on every push to main) and runs it — no Go, no docker build.
#
# Usage (from anywhere on the server):
#   sudo bash /opt/deployment/dashboard/prod-up.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE="${DASHBOARD_IMAGE:-ssdawweq/dokku-dashboard:prod}"
CONTAINER="dokku-dashboard-prod"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.prod.yml"

echo "[+] Pulling latest image: $IMAGE"
docker pull "$IMAGE"
IMAGE_DIGEST="$(docker image inspect "$IMAGE" --format '{{index .RepoDigests 0}}' \
  | awk -F'@' 'NF == 2 {print $2; exit}')"
if [[ ! "$IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "[!] Pulled image did not expose a manifest digest: $IMAGE" >&2
    exit 1
fi
export DASHBOARD_IMAGE_REF="$IMAGE"
export DASHBOARD_IMAGE_DIGEST="$IMAGE_DIGEST"
echo "[+] Resolved manifest digest: $IMAGE_DIGEST"

echo "[+] Stopping old container (if running)..."
docker stop "$CONTAINER" 2>/dev/null || true
docker rm   "$CONTAINER" 2>/dev/null || true

echo "[+] Starting new container..."
docker compose -f "$COMPOSE_FILE" up -d --force-recreate

echo ""
echo "[+] Verifying..."
sleep 3

STATUS=$(docker inspect "$CONTAINER" --format "{{.State.Status}}" 2>/dev/null || echo "not found")
IMAGE_ID=$(docker inspect "$CONTAINER" --format "{{.Image}}" 2>/dev/null | cut -c1-20 || echo "-")

echo "    Container : $CONTAINER"
echo "    Status    : $STATUS"
echo "    Image SHA : $IMAGE_ID..."

if [ "$STATUS" = "running" ]; then
    HEALTH=$(curl -sf http://127.0.0.1:8080/healthz 2>/dev/null || echo "unreachable")
    echo "    Healthz   : $HEALTH"
    echo ""
    echo "[+] Dashboard updated and running at http://127.0.0.1:8080"
else
    echo ""
    echo "[!] Container is not running — check logs:"
    echo "    docker logs $CONTAINER"
    exit 1
fi
