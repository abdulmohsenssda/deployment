#!/usr/bin/env bash
# =============================================================================
# list-tenants.sh — List all Dokku tenants and their status
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib.sh"

# Parse --config
CONFIG_FILE="$PROJECT_DIR/config.env"
for i in $(seq 1 $#); do
    if [ "${!i}" = "--config" ]; then
        j=$((i+1))
        CONFIG_FILE="${!j}"
        break
    fi
done

[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

BASE_DOMAIN="${BASE_DOMAIN:-<not set>}"
STORAGE_ROOT="${STORAGE_ROOT:-/opt/tenant-data}"
public_protocol >/dev/null || exit 1

echo ""
echo "=============================="
echo "  Dokku Tenant Status Report"
echo "=============================="
echo "  Domain: *.${BASE_DOMAIN}"
if [ -n "$(tenant_name_prefix)" ]; then
    echo "  Tenant prefix: $(tenant_name_prefix)"
fi
echo ""

# Get all dokku apps, find tenant pairs (name-backend / name-frontend)
ALL_APPS=$(dokku apps:list 2>/dev/null | tail -n +2 || true)

if [ -z "$ALL_APPS" ]; then
    echo "  No apps found."
    echo ""
    exit 0
fi

# Extract unique tenant names from app names ending in -backend
declare -A TENANTS
while IFS= read -r app; do
    if [[ "$app" == *-backend ]]; then
        tenant="${app%-backend}"
        tenant_in_scope "$tenant" || continue
        TENANTS["$tenant"]=1
    elif [[ "$app" == *-frontend ]]; then
        tenant="${app%-frontend}"
        tenant_in_scope "$tenant" || continue
        TENANTS["$tenant"]=1
    fi
done <<< "$ALL_APPS"

if [ ${#TENANTS[@]} -eq 0 ]; then
    echo "  No tenants found."
    echo ""
    exit 0
fi

printf "  %-18s %-30s %-10s %-10s %-8s\n" "TENANT" "URL" "BACKEND" "FRONTEND" "STORAGE"
printf "  %-18s %-30s %-10s %-10s %-8s\n" "------" "---" "-------" "--------" "-------"

for tenant in $(echo "${!TENANTS[@]}" | tr ' ' '\n' | sort); do
    url="$(public_tenant_url "$tenant")" || url="(invalid public URL)"
    backend_app="${tenant}-backend"
    frontend_app="${tenant}-frontend"

    # Check backend status
    backend_status="missing"
    if dokku apps:exists "$backend_app" 2>/dev/null; then
        running=$(dokku ps:report "$backend_app" 2>/dev/null | grep "Running" | awk '{print $NF}' || echo "0")
        if [ "$running" != "0" ] && [ -n "$running" ]; then
            backend_status="running"
        else
            backend_status="stopped"
        fi
    fi

    # Check frontend status
    frontend_status="missing"
    if dokku apps:exists "$frontend_app" 2>/dev/null; then
        running=$(dokku ps:report "$frontend_app" 2>/dev/null | grep "Running" | awk '{print $NF}' || echo "0")
        if [ "$running" != "0" ] && [ -n "$running" ]; then
            frontend_status="running"
        else
            frontend_status="stopped"
        fi
    fi

    # Check storage
    storage="none"
    if [ -d "$STORAGE_ROOT/$tenant" ]; then
        storage_size=$(du -sh "$STORAGE_ROOT/$tenant" 2>/dev/null | cut -f1 || echo "?")
        storage="$storage_size"
    fi

    printf "  %-18s %-30s %-10s %-10s %-8s\n" "$tenant" "$url" "$backend_status" "$frontend_status" "$storage"
done

echo ""
echo "  Total tenants: ${#TENANTS[@]}"
echo ""
echo "  Useful commands:"
echo "    dokku logs <app> --tail          # View logs"
echo "    dokku ps:report <app>            # Detailed status"
echo "    dokku config:show <app>          # Environment vars"
echo ""
