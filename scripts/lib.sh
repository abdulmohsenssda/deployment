#!/usr/bin/env bash
# =============================================================================
# lib.sh — Shared helpers
# =============================================================================
# Uses host mysql/mysqldump if available, otherwise falls back to Docker.
# Dokku always runs as a Docker container.
#
# Source this file in scripts:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# =============================================================================

# Detect whether this shell should use a local mysql client or a mysql helper
# container. MYSQL_CLIENT_MODE=docker is used by the dashboard runner so MySQL
# grants scoped to Docker bridge clients keep working even if the runner image
# happens to include a mysql binary.
case "${MYSQL_CLIENT_MODE:-auto}" in
    host|docker) _MYSQL_VIA="$MYSQL_CLIENT_MODE" ;;
    auto|"")
        if command -v mysql &>/dev/null; then
            _MYSQL_VIA="host"
        else
            _MYSQL_VIA="docker"
        fi
        ;;
    *)
        echo "[!] Unknown MYSQL_CLIENT_MODE='${MYSQL_CLIENT_MODE}'; using auto detection." >&2
        if command -v mysql &>/dev/null; then
            _MYSQL_VIA="host"
        else
            _MYSQL_VIA="docker"
        fi
        ;;
esac

# Resolve the MySQL host for the *current* execution context.
# `host.docker.internal` is a Docker-only DNS name and does NOT resolve on
# the host itself, so when we shell out to the host's mysql client we must
# translate it to a loopback address. Inside a container the original name
# is preserved (with `--add-host=host.docker.internal:host-gateway`).
_resolve_mysql_host() {
    local h="${1:-${MYSQL_HOST:-127.0.0.1}}"
    case "$h" in
        localhost|127.0.0.1|::1)
            if [ "$_MYSQL_VIA" = "docker" ]; then
                echo "host.docker.internal"
            else
                echo "127.0.0.1"
            fi
            ;;
        host.docker.internal)
            if [ "$_MYSQL_VIA" = "host" ]; then
                echo "127.0.0.1"
            else
                echo "host.docker.internal"
            fi
            ;;
        *) echo "$h" ;;
    esac
}

# Hostname to inject into app containers. A container's localhost is the app
# container itself, so local host aliases must become Docker's host gateway.
mysql_host_for_container() {
    local h="${1:-${MYSQL_HOST:-host.docker.internal}}"
    case "$h" in
        localhost|127.0.0.1|::1) echo "host.docker.internal" ;;
        *) echo "$h" ;;
    esac
}

# Discover the actual host port the Dokku container publishes 80/tcp on.
# Falls back to $DOKKU_PORT (or 8080) if docker inspection fails. Config
# drift (config.env says 8080 but dokku was started with -p 8085:80) was
# a real 404-source for the tenant-seed step.
dokku_host_port() {
    local port container
    container="${DOKKU_CONTAINER:-dokku}"
    port="$(docker port "$container" 80/tcp 2>/dev/null | awk -F':' 'NR==1 {print $NF; exit}')"
    if [ -n "$port" ]; then
        echo "$port"
    else
        echo "${DOKKU_PORT:-8080}"
    fi
}


sanitize_tenant_name() {
    printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/^-*//;s/-*$//'
}

tenant_name_prefix() {
    local prefix
    prefix="$(sanitize_tenant_name "${TENANT_NAME_PREFIX_OVERRIDE:-${TENANT_NAME_PREFIX:-}}")"
    [ -z "$prefix" ] && return 0
    case "$prefix" in
        *-) printf '%s' "$prefix" ;;
        *)  printf '%s-' "$prefix" ;;
    esac
}

tenant_full_name() {
    local tenant prefix
    tenant="$(sanitize_tenant_name "$1")"
    prefix="$(tenant_name_prefix)"
    if [ -n "$prefix" ] && [[ "$tenant" != "$prefix"* ]]; then
        tenant="${prefix}${tenant}"
    fi
    if [ -z "$tenant" ] || [ ${#tenant} -gt 63 ]; then
        echo "Invalid tenant name after applying TENANT_NAME_PREFIX: $tenant" >&2
        return 1
    fi
    printf '%s' "$tenant"
}

tenant_in_scope() {
    local tenant prefix
    tenant="$(sanitize_tenant_name "$1")"
    prefix="$(tenant_name_prefix)"
    [ -z "$prefix" ] || [[ "$tenant" == "$prefix"* ]]
}

# tenant_auto_redeploy_enabled <tenant>
#   Returns success unless the dashboard state file or the compatibility
#   AUTO_REDEPLOY_DISABLED list explicitly disables automatic deployment.
tenant_auto_redeploy_enabled() {
    local tenant="$1" raw item norm state_file
    state_file="${TENANT_STATE_DIR:-/opt/tenant-state}/${tenant}.json"
    if [ -f "$state_file" ] &&
        grep -Eq '"auto_redeploy"[[:space:]]*:[[:space:]]*false([[:space:]]*[,}])?' "$state_file"; then
        return 1
    fi

    raw="${AUTO_REDEPLOY_DISABLED:-}"
    [ -z "$raw" ] && return 0
    for item in ${raw//,/ }; do
        norm="$(tenant_full_name "$item" 2>/dev/null || echo "$item")"
        if [ "$norm" = "$tenant" ] || [ "$item" = "$tenant" ]; then
            return 1
        fi
    done
    return 0
}

tenant_from_app_name() {
    local app="$1"
    case "$app" in
        *-backend)  printf '%s' "${app%-backend}" ;;
        *-frontend) printf '%s' "${app%-frontend}" ;;
        *)          printf '%s' "$app" ;;
    esac
}

# Resolve and validate the single scheme used by generated public URLs.
# Dashboard production runners set DASHBOARD_ENV=prod; direct installs can
# opt into the same behavior with ENABLE_SSL=true or PUBLIC_PROTOCOL=https.
public_protocol() {
    local protocol="${PUBLIC_PROTOCOL:-}" env="${DASHBOARD_ENV:-}" ssl="${ENABLE_SSL:-false}"
    env="${env,,}"
    ssl="${ssl,,}"
    if [ -z "$protocol" ]; then
        case "$env" in
            prod|production) protocol="https" ;;
            *) [ "$ssl" = "true" ] && protocol="https" || protocol="http" ;;
        esac
    fi
    protocol="$(printf '%s' "$protocol" | tr '[:upper:]' '[:lower:]')"
    case "$protocol" in
        http|https) ;;
        *)
            echo "Invalid PUBLIC_PROTOCOL='$protocol'; expected http or https." >&2
            return 1
            ;;
    esac
    case "$env" in
        prod|production)
            if [ "$protocol" != "https" ]; then
                echo "Production public URLs must use HTTPS." >&2
                return 1
            fi
            ;;
    esac
    printf '%s' "$protocol"
}

is_local_public_host() {
    local host="${1,,}"
    case "$host" in
        ::1|[::1]|::|[::]) return 0 ;;
    esac
    host="${host%%:*}"
    case "$host" in
        localhost|*.localhost|localtest.me|*.localtest.me|127.*|0.0.0.0)
            return 0
            ;;
        *) return 1 ;;
    esac
}

# Build one validated public URL from a hostname. The input deliberately
# excludes a scheme so callers cannot accidentally mix HTTP and HTTPS links.
public_url() {
    local host="$1"
    local protocol env
    protocol="$(public_protocol)" || return 1
    env="${DASHBOARD_ENV:-}"
    env="${env,,}"
    if [ -z "$host" ] || [[ "$host" == *"://"* || "$host" == */* || "$host" == *[[:space:]]* ]]; then
        echo "Invalid public host '$host'." >&2
        return 1
    fi
    if [[ "$env" = "prod" || "$env" = "production" ]] &&
        is_local_public_host "$host"; then
        echo "Production public URLs must not target localhost, localtest.me, or a loopback address." >&2
        return 1
    fi
    printf '%s://%s' "$protocol" "$host"
}

public_tenant_url() {
    local tenant base_domain env
    base_domain="${BASE_DOMAIN:?BASE_DOMAIN not set}"
    env="${DASHBOARD_ENV:-}"
    env="${env,,}"
    if [[ "$env" = "prod" || "$env" = "production" ]] &&
        is_local_public_host "$base_domain"; then
        echo "Production public URLs must not use a localhost, localtest.me, or loopback BASE_DOMAIN." >&2
        return 1
    fi
    tenant="$(tenant_full_name "$1")" || return 1
    public_url "${tenant}.${base_domain}"
}

# Reconcile Dokku's persisted public routing for one tenant.
#
# Dokku stores domains and config independently from BASE_DOMAIN. Callers that
# may deploy or rebuild an app should run this before doing so, so a later
# image or migration failure cannot leave the tenant on its old public URL.
# ROUTING_RESTARTED is set for callers that need to avoid a duplicate restart.
reconcile_tenant_routing() {
    local tenant="${1:-}"
    local restart_mode="${2:-on-change}"
    local tenant_domain public_url_value backend_app frontend_app
    local frontend_domains backend_domains app_domain api_url
    local frontend_domain_present=false
    local routing_changed=false

    [ -n "$tenant" ] || {
        echo "Tenant name is required for routing reconciliation." >&2
        return 1
    }

    tenant="$(tenant_full_name "$tenant")" || return 1
    tenant_domain="${tenant}.${BASE_DOMAIN:?BASE_DOMAIN not set}"
    public_url_value="$(public_tenant_url "$tenant")" || return 1
    backend_app="${tenant}-backend"
    frontend_app="${tenant}-frontend"
    ROUTING_RESTARTED=false

    frontend_domains="$(dokku domains:report "$frontend_app" --domains-app-vhosts 2>/dev/null || true)"
    backend_domains="$(dokku domains:report "$backend_app" --domains-app-vhosts 2>/dev/null || true)"
    app_domain="$(dokku config:get "$frontend_app" APP_DOMAIN 2>/dev/null || true)"
    api_url="$(dokku config:get "$frontend_app" API_URL 2>/dev/null || true)"

    local domain
    for domain in $frontend_domains; do
        if [ "$domain" = "$tenant_domain" ]; then
            frontend_domain_present=true
            break
        fi
    done
    if ! $frontend_domain_present || [ "$app_domain" != "$tenant_domain" ] ||
        [ "$api_url" != "${public_url_value}/api" ] ||
        [ -n "$(printf '%s' "$backend_domains" | tr -d '[:space:]')" ]; then
        routing_changed=true
    fi

    # Backend stays internal-only; frontend owns the public hostname.
    dokku domains:clear "$backend_app" >/dev/null || true
    dokku proxy:disable "$backend_app" >/dev/null 2>&1 || true
    dokku domains:clear "$frontend_app" >/dev/null
    dokku domains:add "$frontend_app" "$tenant_domain" >/dev/null
    dokku config:set --no-restart "$frontend_app" \
        APP_DOMAIN="$tenant_domain" \
        API_URL="${public_url_value}/api"

    if [ "$routing_changed" = true ] && [ "$restart_mode" != "no-restart" ]; then
        dokku ps:restart "$frontend_app"
        ROUTING_RESTARTED=true
    fi
}

# Resolve the control-plane MySQL account at call time. Helpers are sourced
# before individual scripts load config.env, so this must not be cached here.
# MYSQL_ROOT_* remains a compatibility fallback for existing installations;
# the account is an admin/deployer account and is not required to be MySQL root.
mysql_admin_user() {
    if [ -n "${MYSQL_ADMIN_USER:-}" ]; then
        printf '%s' "$MYSQL_ADMIN_USER"
    elif [ -n "${MYSQL_ROOT_USER:-}" ]; then
        printf '%s' "$MYSQL_ROOT_USER"
    elif [ -n "${MYSQL_ROOT_PASSWORD:-}" ] && [ -z "${MYSQL_ADMIN_PASSWORD:-}" ]; then
        # Old installs set only MYSQL_ROOT_PASSWORD and used root implicitly.
        printf '%s' "root"
    else
        printf '%s' "dokku_admin"
    fi
}

mysql_admin_password() {
    printf '%s' "${MYSQL_ADMIN_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"
}

mysql_admin_configured() {
    local password
    password="$(mysql_admin_password)"
    [ -n "$password" ] && [ "$password" != "changeme" ]
}

# MySQL client (supports stdin/heredocs)
run_mysql() {
    local host user password
    host="$(_resolve_mysql_host)"
    user="$(mysql_admin_user)"
    password="$(mysql_admin_password)"
    if [ "${DASHBOARD_ENV:-}" = "dev" ]; then
        echo -e "${BLUE:-}[i]${NC:-} [dev-diag] run_mysql via=${_MYSQL_VIA} host=${host} port=${MYSQL_PORT:-3306} user=${user} args=[$*]" >&2
    fi
    if [ "$_MYSQL_VIA" = "host" ]; then
        MYSQL_PWD="$password" \
            mysql --protocol=TCP -h "$host" -P "${MYSQL_PORT:-3306}" -u "$user" "$@"
    else
        docker run --rm -i \
            --add-host=host.docker.internal:host-gateway \
            -e "MYSQL_PWD=${password}" \
            mysql:8.0 \
            mysql --protocol=TCP -h "$host" -P "${MYSQL_PORT:-3306}" -u "$user" "$@"
    fi
}

# mysqldump (stdout flows to host for piping)
run_mysqldump() {
    local host user password
    host="$(_resolve_mysql_host)"
    user="$(mysql_admin_user)"
    password="$(mysql_admin_password)"
    if [ "$_MYSQL_VIA" = "host" ]; then
        MYSQL_PWD="$password" \
            mysqldump --protocol=TCP -h "$host" -P "${MYSQL_PORT:-3306}" -u "$user" "$@"
    else
        docker run --rm \
            --add-host=host.docker.internal:host-gateway \
            -e "MYSQL_PWD=${password}" \
            mysql:8.0 \
            mysqldump --protocol=TCP -h "$host" -P "${MYSQL_PORT:-3306}" -u "$user" "$@"
    fi
}

# Ensure the Dokku container exists and is running. If it's missing or
# stopped, try to (re)create / start it via setup-dokku.sh, sourcing
# install.env / config.env first so DOKKU_PORT and DOKKU_HOSTNAME come from
# the operator's configuration. On failure, dump the last 200 lines of
# `docker logs <dokku-container>` so the caller doesn't have to dig for the reason.
#
# Idempotent and cheap: a running container short-circuits in O(1).
ensure_dokku_running() {
    [ -n "${_DOKKU_ENSURED:-}" ] && return 0

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local repo_dir
    repo_dir="$(dirname "$script_dir")"

    # Source config.env first then install.env so the operator's install.env
    # wins over the auto-generated config.env (matches setup-dokku.sh).
    local f
    for f in "$repo_dir/config.env" "$repo_dir/install.env"; do
        if [ -f "$f" ]; then
            # shellcheck disable=SC1090
            set -a; . "$f"; set +a
        fi
    done

    # DOKKU_CONTAINER can be set in config.env (e.g. "dokku-test-local") or
    # defaults to "dokku" for production installs.
    local _dc="${DOKKU_CONTAINER:-dokku}"

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${_dc}"; then
        export _DOKKU_ENSURED=1
        return 0
    fi

    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${_dc}"; then
        echo "[+] dokku container exists but is not running — starting it..." >&2
        if docker start "${_dc}" >/dev/null 2>&1; then
            export _DOKKU_ENSURED=1
            return 0
        fi
        echo "[✗] Failed to start existing dokku container. Last 200 log lines:" >&2
        docker logs --tail 200 "${_dc}" 2>&1 | sed 's/^/    /' >&2
        return 1
    fi

    echo "[+] dokku container not found — bootstrapping via setup-dokku.sh" >&2
    if ! bash "$script_dir/setup-dokku.sh" >&2; then
        echo "[✗] setup-dokku.sh failed. Last 200 log lines from dokku container (if any):" >&2
        docker logs --tail 200 "${_dc}" 2>&1 | sed 's/^/    /' >&2 || true
        return 1
    fi
    export _DOKKU_ENSURED=1
    return 0
}

# Run a shell command inside the Dokku container
dokku_shell() {
    ensure_dokku_running || return 1
    _dokku_fix_hostname
    docker exec -i "${DOKKU_CONTAINER:-dokku}" bash -c "$*"
}

# Wrapper for the `dokku` CLI. Dokku always runs as a Docker container in this
# setup; defining this as a shell function means every script that sources
# lib.sh gets a working `dokku` even when /usr/local/bin/dokku is missing
# (e.g. setup.sh died before it wrote the wrapper, or PATH is sanitized by
# sudo). The function takes precedence over any binary on PATH within this
# shell, so behavior stays consistent across hosts.
dokku() {
    ensure_dokku_running || return 1
    _dokku_fix_hostname
    docker exec -i "${DOKKU_CONTAINER:-dokku}" dokku "$@"
}

# Deploy an app from a Docker image. Dokku's git:from-image returns non-zero
# when the image reference string did not change, even if the tag was re-pushed
# and already pulled locally. In that case, rebuild the existing image source so
# same-version rollouts are still deployable.
dokku_git_from_image() {
    local app="$1" image="$2" out rc
    if out="$(dokku git:from-image "$app" "$image" 2>&1)"; then
        printf '%s\n' "$out"
        return 0
    fi
    rc=$?
    printf '%s\n' "$out"
    if printf '%s\n' "$out" | grep -qi 'No changes detected'; then
        echo "[!] No source image ref change for $app; rebuilding existing Dokku image source." >&2
        dokku ps:rebuild "$app"
        return $?
    fi
    return "$rc"
}

# Record the public, non-secret build identity alongside the Dokku config.
# Dokku often replaces the configured image with a local dokku/<app>:latest
# image, so status must retain the requested image ref and resolved digest.
record_build_identity() {
    local app="$1" image="$2" version digest commit short_commit channel source workflow_id workflow_url built_at deployed_at
    version="$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$image" 2>/dev/null || true)"
    [ -z "$version" ] || [ "$version" = "<no value>" ] && version=""
    if [ -z "$version" ]; then
        version="${image##*:}"
    fi
    digest="$(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$image" 2>/dev/null \
        | awk -F@ 'NF==2 {print $2; exit}')"
    if [ -z "$digest" ] && [[ "$image" == *@sha256:* ]]; then
        digest="${image##*@}"
    fi
    commit="$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$image" 2>/dev/null || true)"
    [ "$commit" = "<no value>" ] && commit=""
    short_commit="$commit"
    [ ${#short_commit} -gt 7 ] && short_commit="${short_commit:0:7}"
    channel="$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.channel"}}' "$image" 2>/dev/null || true)"
    [ "$channel" = "<no value>" ] && channel=""
    source="$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.source"}}' "$image" 2>/dev/null || true)"
    [ "$source" = "<no value>" ] && source=""
    workflow_id="$(docker image inspect -f '{{index .Config.Labels "com.ifritah.build.workflow_run_id"}}' "$image" 2>/dev/null || true)"
    [ "$workflow_id" = "<no value>" ] && workflow_id=""
    workflow_url="$(docker image inspect -f '{{index .Config.Labels "com.ifritah.build.workflow_run_url"}}' "$image" 2>/dev/null || true)"
    [ "$workflow_url" = "<no value>" ] && workflow_url=""
    built_at="$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.created"}}' "$image" 2>/dev/null || true)"
    [ "$built_at" = "<no value>" ] && built_at=""
    deployed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    dokku config:set --no-restart "$app" \
        APP_VERSION="$version" \
        APP_CHANNEL="$channel" \
        APP_COMMIT="$commit" \
        APP_CREATED="$built_at" \
        APP_IMAGE_CHANNEL="$channel" \
        APP_IMAGE_VERSION="$version" \
        APP_IMAGE_COMMIT="$commit" \
        APP_IMAGE_COMMIT_SHORT="$short_commit" \
        APP_IMAGE_CHANNEL="$channel" \
        APP_SOURCE="$source" \
        APP_IMAGE_REF="$image" \
        APP_IMAGE_DIGEST="$digest" \
        APP_WORKFLOW_RUN_ID="$workflow_id" \
        APP_WORKFLOW_RUN_URL="$workflow_url" \
        APP_WORKFLOW_RUN="$workflow_id" \
        APP_BUILT_AT="$built_at" \
        APP_DEPLOYED_AT="$deployed_at"
}

# Silence the harmless but noisy "sudo: unable to resolve host <containerid>"
# warning that Dokku's internal sudo calls produce when the dokku container
# was started without --hostname. Idempotent: only writes /etc/hosts once per
# shell, and only if the entry is actually missing inside the container.
_dokku_fix_hostname() {
    [ -n "${_DOKKU_HOSTS_FIXED:-}" ] && return 0
    local _dc="${DOKKU_CONTAINER:-dokku}"
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${_dc}" || return 0
    local h
    h=$(docker exec "${_dc}" hostname 2>/dev/null) || return 0
    [ -n "$h" ] || return 0
    if ! docker exec "${_dc}" grep -q "[[:space:]]${h}\$" /etc/hosts 2>/dev/null; then
        docker exec -u root "${_dc}" sh -c "echo '127.0.1.1 ${h}' >> /etc/hosts" 2>/dev/null || true
    fi
    export _DOKKU_HOSTS_FIXED=1
}

# =============================================================================
# Host port allocation (used in NGINX_MODE=behind-nginx)
# =============================================================================
# _collect_used_ports
#   Prints, one per line, every TCP port we want to avoid when allocating a
#   new host-side port for a tenant app:
#     1. Host-side ports already mapped by any existing Dokku app
#     2. Ports currently listening on this host (best-effort; the dashboard
#        sidecar's network namespace may differ from the real host, but Dokku
#        port-map dedup is the critical invariant)
_collect_used_ports() {
    local apps app
    apps="$(dokku --quiet apps:list 2>/dev/null || true)"
    for app in $apps; do
        # `dokku ports:report <app> --proxy-port-map` returns
        #   "http:18000:8000 https:18443:8000 ..."
        dokku ports:report "$app" --proxy-port-map 2>/dev/null \
            | tr ' ' '\n' \
            | awk -F: '/^[a-zA-Z]+:[0-9]+:[0-9]+$/ {print $2}'
    done
    if command -v ss &>/dev/null; then
        ss -ltn 2>/dev/null | awk 'NR>1 {n=split($4,a,":"); print a[n]}'
    elif command -v netstat &>/dev/null; then
        netstat -ltn 2>/dev/null | awk 'NR>2 {n=split($4,a,":"); print a[n]}'
    fi
}

# allocate_host_port <range_start> <range_end> [exclude_csv]
#   Echoes the lowest free port in [range_start, range_end] not in the used
#   set or in the comma-separated exclusion list. Returns 1 if none free.
allocate_host_port() {
    local start="$1" end="$2" exclude_csv="${3:-}"
    local used p x skip
    used="$(_collect_used_ports | sort -un)"
    for ((p=start; p<=end; p++)); do
        if echo "$used" | grep -qx "$p"; then continue; fi
        skip=0
        if [ -n "$exclude_csv" ]; then
            local IFS=','
            for x in $exclude_csv; do
                if [ "$x" = "$p" ]; then skip=1; break; fi
            done
        fi
        [ "$skip" -eq 1 ] && continue
        echo "$p"
        return 0
    done
    return 1
}

# Get remote Docker Hub image digest (public, anonymous)
get_remote_digest() {
    local image="$1"
    local tag="${2:-latest}"
    local repo="$image"
    [[ "$repo" != *"/"* ]] && repo="library/$repo"

    local token_response token headers digest
    token_response=$(curl -fsS "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull") || {
        echo "Docker Hub token request failed for ${image}:${tag}" >&2
        return 1
    }
    token=$(printf '%s' "$token_response" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
    [ -n "$token" ] || {
        echo "Docker Hub token response did not contain a token for ${image}:${tag}" >&2
        return 1
    }

    headers=$(curl -fsS -D - -o /dev/null -H "Authorization: Bearer ${token}" \
        -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
        -H "Accept: application/vnd.oci.image.index.v1+json" \
        "https://registry-1.docker.io/v2/${repo}/manifests/${tag}") || {
        echo "Docker Hub manifest request failed for ${image}:${tag}" >&2
        return 1
    }
    digest=$(printf '%s\n' "$headers" | grep -i "docker-content-digest" | awk '{print $2}' | tr -d '\r' | head -n1)
    [ -n "$digest" ] || {
        echo "Docker Hub did not return a digest for ${image}:${tag}" >&2
        return 1
    }
    printf '%s\n' "$digest"
}

# Canonical state helpers shared by the poller and webhook. The state key
# includes the app type and tag, so a webhook for DEV_TAG updates the exact
# file read by auto-pull.sh instead of creating a second cache entry.
auto_pull_state_dir() {
    printf '%s' "${AUTO_PULL_STATE_DIR:-/var/lib/auto-pull}"
}

auto_pull_digest_component() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_.-]/-/g'
}

auto_pull_digest_key() {
    local app_type tag
    app_type="$(auto_pull_digest_component "$1")"
    tag="$(auto_pull_digest_component "${2:-latest}")"
    [ -n "$app_type" ] && [ -n "$tag" ] || return 1
    printf '%s-%s' "$app_type" "$tag"
}

auto_pull_digest_path() {
    local app_type="$1" tag="${2:-latest}" state_dir="${3:-$(auto_pull_state_dir)}"
    printf '%s/%s.digest' "$state_dir" "$(auto_pull_digest_key "$app_type" "$tag")"
}

auto_pull_digest_tenant_key() {
    local tenant
    tenant="$(auto_pull_digest_component "$1")"
    [ -n "$tenant" ] || return 1
    printf 'tenant_%s' "$tenant"
}

# Read the last deployed digest. Older installs wrote <type>.digest; use that
# file only for the configured DEV_TAG and migrate it on the next successful
# deployment, which avoids replaying an already deployed webhook.
auto_pull_digest_read() {
    local app_type="$1" tag="${2:-latest}" state_dir="${3:-$(auto_pull_state_dir)}"
    local path legacy value
    path="$(auto_pull_digest_path "$app_type" "$tag" "$state_dir")" || return 1
    if [ -f "$path" ]; then
        value="$(sed -n 's/^last_deployed_digest=//p' "$path" | head -n1)"
        [ -n "$value" ] && { printf '%s\n' "$value"; return 0; }
        sed -n '1p' "$path"
        return 0
    fi
    legacy="${state_dir}/$(auto_pull_digest_component "$app_type").digest"
    if [ "$tag" = "${DEV_TAG:-}" ] && [ "$legacy" != "$path" ] && [ -f "$legacy" ]; then
        sed -n '1p' "$legacy"
    fi
}

# Read tenant-specific state first, then fall back to the all-tenant state.
# This keeps a targeted webhook from making the poller skip tenants that have
# not received the image yet, while preserving compatibility with old state.
auto_pull_digest_read_for_tenant() {
    local app_type="$1" tag="${2:-latest}" tenant="$3" state_dir="${4:-$(auto_pull_state_dir)}"
    local path tenant_key value
    path="$(auto_pull_digest_path "$app_type" "$tag" "$state_dir")" || return 1
    tenant_key="$(auto_pull_digest_tenant_key "$tenant")" || return 1
    if [ -f "$path" ]; then
        value="$(awk -F= -v key="${tenant_key}_last_deployed_digest" \
            '$1 == key {print substr($0, index($0, "=") + 1); exit}' "$path")"
        [ -n "$value" ] && { printf '%s\n' "$value"; return 0; }
    fi
    auto_pull_digest_read "$app_type" "$tag" "$state_dir"
}

# Write all-tenant reconciliation state with a same-directory rename so
# readers never see a partial file. Tenant markers are removed because every
# eligible tenant has just been reconciled and the global marker supersedes
# them. Callers must hold the shared auto-pull lock.
auto_pull_digest_write() {
    local app_type="$1" tag="$2" digest="$3" image="${4:-}" state_dir="${5:-$(auto_pull_state_dir)}"
    local path tmp
    [ -n "$digest" ] || return 1
    path="$(auto_pull_digest_path "$app_type" "$tag" "$state_dir")" || return 1
    mkdir -p "$state_dir"
    tmp="${path}.$$"
    umask 077
    {
        printf 'last_seen_digest=%s\n' "$digest"
        printf 'last_deployed_digest=%s\n' "$digest"
        [ -n "$image" ] && printf 'image=%s\n' "$image"
        printf 'tag=%s\n' "$tag"
        printf 'updated_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$path"
}

# Write only one tenant/component marker while preserving the canonical
# app-type/tag file and any other tenant markers. The rename makes retries
# idempotent and prevents readers from observing a partial state file.
auto_pull_digest_write_for_tenant() {
    local app_type="$1" tag="$2" tenant="$3" digest="$4" image="${5:-}" state_dir="${6:-$(auto_pull_state_dir)}"
    local path tmp tenant_key preserved
    [ -n "$digest" ] || return 1
    path="$(auto_pull_digest_path "$app_type" "$tag" "$state_dir")" || return 1
    tenant_key="$(auto_pull_digest_tenant_key "$tenant")" || return 1
    mkdir -p "$state_dir"
    tmp="${path}.$$"
    umask 077
    preserved=""
    if [ -f "$path" ]; then
        preserved="$(awk -F= -v prefix="${tenant_key}_" '
            index($1, prefix) != 1 { print }
        ' "$path")"
    fi
    {
        [ -z "$preserved" ] || printf '%s\n' "$preserved"
        printf '%s_last_seen_digest=%s\n' "$tenant_key" "$digest"
        printf '%s_last_deployed_digest=%s\n' "$tenant_key" "$digest"
        printf '%s_updated_at=%s\n' "$tenant_key" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$path"
}

auto_pull_cron_line() {
    local script="$1" config="$2"
    printf '*/2 * * * * %q --config %q >> /var/log/auto-pull.log 2>&1' "$script" "$config"
}

# Install exactly one poller entry while preserving unrelated crontab entries.
ensure_auto_pull_schedule() {
    local script="$1" config="$2" existing filtered line
    command -v crontab >/dev/null 2>&1 || {
        echo "crontab is unavailable; install cron before enabling auto-pull." >&2
        return 1
    }
    existing="$(crontab -l 2>/dev/null || true)"
    filtered="$(printf '%s\n' "$existing" | grep -v 'auto-pull\.sh' || true)"
    line="$(auto_pull_cron_line "$script" "$config")"
    {
        [ -z "$filtered" ] || printf '%s\n' "$filtered"
        printf '%s\n' "$line"
    } | crontab - || {
        echo "failed to install auto-pull crontab entry." >&2
        return 1
    }
    if ! crontab -l 2>/dev/null | grep -Fq -- "$script"; then
        echo "auto-pull crontab verification failed; expected ${script}." >&2
        return 1
    fi
}

auto_pull_cron_status() {
    local script="${1:-}" output rc
    if ! command -v crontab >/dev/null 2>&1; then
        printf 'error\tcrontab command unavailable; install cron and rerun setup.sh'
        return 0
    fi
    if output="$(crontab -l 2>&1)"; then
        rc=0
    else
        rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        if printf '%s' "$output" | grep -qi 'no crontab for'; then
            printf 'absent\tNo user crontab exists; run sudo bash %s' "${script:-scripts/setup.sh}"
        else
            printf 'error\tUnable to read user crontab (exit %s): %s' "$rc" "$output"
        fi
        return 0
    fi
    if ! printf '%s\n' "$output" | grep -q 'auto-pull\.sh'; then
        printf 'absent\tAuto-pull cron entry is missing; run sudo bash %s' "${script:-scripts/setup.sh}"
        return 0
    fi
    if [ -n "$script" ] && [ ! -x "$script" ]; then
        printf 'error\tAuto-pull cron exists but script is missing or not executable: %s' "$script"
        return 0
    fi
    printf 'active\tAuto-pull cron is installed and references auto-pull.sh'
}

# =============================================================================
# Backup metadata helpers
# =============================================================================
# A backup "set" is one timestamped run for a tenant. It is described by a
# sidecar manifest file named "<tenant>_<timestamp>.meta.json" living next to
# the .tar.gz / .sql.gz artifacts in BACKUP_DIR. The manifest lets the backup
# tooling distinguish user-created backups (protected from policy deletion)
# from automatic backups (retained/deleted by the retention policy), and
# records whether the artifacts passed integrity verification.

# backup_id <tenant> <timestamp> -> the stable id for a backup set.
backup_id() { printf '%s_%s' "$1" "$2"; }

# json_escape <string> -> minimally escaped JSON string body (no quotes).
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# Read a scalar string field from a backup manifest file. Best-effort JSON
# scraping that avoids a jq dependency (the runner image may not ship jq).
#   backup_meta_field <meta-file> <field>
backup_meta_field() {
    local file="$1" field="$2"
    [ -f "$file" ] || return 1
    local value
    value="$(sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$file" | head -n1)"
    if [ -n "$value" ]; then
        printf '%s\n' "$value"
        return 0
    fi
    sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\\(true\\|false\\|[0-9][0-9]*\\).*/\\1/p" "$file" | head -n1
}

# Verify a gzip artifact's integrity. Works for both .tar.gz (verifies the
# tar stream too) and .sql.gz. Returns non-zero on any corruption/empty file.
verify_gzip_artifact() {
    local file="$1"
    [ -f "$file" ] || return 1
    [ -s "$file" ] || return 1
    gzip -t "$file" 2>/dev/null || return 1
    case "$file" in
        *.tar.gz) tar -tzf "$file" >/dev/null 2>&1 || return 1 ;;
    esac
    return 0
}

# backup_artifact_path <artifact> -> absolute path inside BACKUP_DIR.
# Manifest artifact names are generated by this repository and must remain
# basenames so a corrupt manifest cannot make cleanup or restore touch another
# path.
backup_artifact_path() {
    local artifact="$1"
    case "$artifact" in
        ""|"."|".."|*/*|*\\*) return 1 ;;
    esac
    printf '%s/%s' "${BACKUP_DIR:?BACKUP_DIR is not set}" "$artifact"
}

valid_backup_id() {
    local id="$1"
    [ -n "$id" ] && [ ${#id} -le 80 ] || return 1
    case "$id" in
        *[!A-Za-z0-9_-]*) return 1 ;;
    esac
}

# Write a backup manifest. Positional args keep callers simple:
#   write_backup_manifest <meta-file> <tenant> <timestamp> <origin> <owner> \
#                         <files-artifact|-> <db-artifact|-> <verified:true|false> [label]
write_backup_manifest() {
    local meta="$1" tenant="$2" ts="$3" origin="$4" owner="$5" files="$6" db="$7" verified="$8" label="${9:-}"
    local files_base="" db_base=""
    [ "$files" != "-" ] && [ -n "$files" ] && files_base="$(basename "$files")"
    [ "$db" != "-" ] && [ -n "$db" ] && db_base="$(basename "$db")"
    cat > "$meta" <<EOF
{
  "id": "$(json_escape "$(backup_id "$tenant" "$ts")")",
  "tenant": "$(json_escape "$tenant")",
  "timestamp": "$(json_escape "$ts")",
  "origin": "$(json_escape "$origin")",
  "owner": "$(json_escape "$owner")",
  "label": "$(json_escape "$label")",
  "files_artifact": "$(json_escape "$files_base")",
  "db_artifact": "$(json_escape "$db_base")",
  "label": "$(json_escape "$label")",
  "verified": ${verified},
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

EOF
}

# verified_tenant_db_backup <tenant> [backup-dir]
#   Prints "<backup-id>\t<db-artifact>\t<meta-file>" for the newest verified
#   backup containing a readable tenant SQL dump. A verified files-only set is
#   deliberately not sufficient for migration safety.
verified_tenant_db_backup() {
    local tenant="$1" backup_dir="${2:-${BACKUP_DIR:-/opt/tenant-backups}}"
    local meta manifest_tenant verified db db_path backup_id
    while IFS= read -r meta; do
        [ -n "$meta" ] || continue
        manifest_tenant="$(backup_meta_field "$meta" tenant || true)"
        [ "$manifest_tenant" = "$tenant" ] || continue
        verified="$(backup_meta_field "$meta" verified || true)"
        [ "$verified" = "true" ] || continue
        db="$(backup_meta_field "$meta" db_artifact || true)"
        [ -n "$db" ] || continue
        db_path="$backup_dir/$db"
        verify_gzip_artifact "$db_path" || continue
        backup_id="$(backup_meta_field "$meta" id || true)"
        [ -n "$backup_id" ] || backup_id="$(basename "$meta" .meta.json)"
        printf '%s\t%s\t%s\n' "$backup_id" "$db_path" "$meta"
        return 0
    done < <(find "$backup_dir" -maxdepth 1 -type f -name "${tenant}_*.meta.json" 2>/dev/null | sort -r)
    return 1
}

# create_verified_tenant_db_backup <tenant> <config-file>
#   Creates and verifies an automatic backup, then returns its durable identity.
create_verified_tenant_db_backup() {
    local tenant="$1" config_file="$2"
    local backup_dir="${BACKUP_DIR:-/opt/tenant-backups}"
    bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/backup-tenant.sh" \
        "$tenant" --origin auto --owner deployment --require-verified --no-prune \
        --config "$config_file" >/dev/null || return 1
    verified_tenant_db_backup "$tenant" "$backup_dir"
}
