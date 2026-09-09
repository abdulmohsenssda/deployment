#!/usr/bin/env bash
# =============================================================================
# status.sh — Live status of all Dokku tenants on this server
# =============================================================================
# Prints a single-pass report of:
#   - Dokku container health
#   - Per-app process state (running/restarting/crashed) and restart count
#   - Currently deployed image
#   - Domains, internal Dokku-network port, host-published port (if any)
#   - HTTP probe (in-container) result
#   - Master-DB tenant pin (next image auto-pull will deploy)
#   - Auto-pull cron state (active/absent/error) and diagnostics
#
# Usage:
#   sudo bash scripts/status.sh                  # all tenants, summary
#   sudo bash scripts/status.sh --tenant dev     # one tenant, verbose
#   sudo bash scripts/status.sh --watch          # refresh every 5s (Ctrl-C to exit)
#   sudo bash scripts/status.sh --json           # machine-readable
#   sudo bash scripts/status.sh --config /opt/deployment/config.dev.env
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_DIR/config.env"
TENANT_FILTER=""
WATCH=false
JSON=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)  CONFIG_FILE="$2"; shift 2 ;;
        --tenant)  TENANT_FILTER="$2"; shift 2 ;;
        --watch)   WATCH=true; shift ;;
        --json)    JSON=true; shift ;;
        -h|--help) sed -n '1,25p' "$0"; exit 0 ;;
        *)         echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done

[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/tenant-provenance.sh"

if [ -n "$TENANT_FILTER" ]; then
    TENANT_FILTER="$(tenant_full_name "$TENANT_FILTER")" || exit 1
fi

BASE_DOMAIN="${BASE_DOMAIN:-<unset>}"
MYSQL_MASTER_DB="${MYSQL_MASTER_DB:-zatca_master}"
AUTO_PULL_STATUS_LINE="$(auto_pull_cron_status "$SCRIPT_DIR/auto-pull.sh")"
IFS=$'\t' read -r AUTO_PULL_STATE AUTO_PULL_DIAGNOSTIC <<< "$AUTO_PULL_STATUS_LINE"

# ---- Colors (auto-disabled if not a TTY or --json) ---------------------------
if $JSON || [ ! -t 1 ]; then
    R=""; G=""; Y=""; B=""; D=""; N=""
else
    R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[1;33m'
    B=$'\033[0;34m'; D=$'\033[2m';   N=$'\033[0m'
fi

# ---- Helpers -----------------------------------------------------------------
have_dokku_container() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'dokku'
}

# Echoes status of the dokku container itself: "running"/"stopped"/"missing"
dokku_state() {
    if ! docker inspect dokku &>/dev/null; then
        echo "missing"; return
    fi
    docker inspect -f '{{.State.Status}}' dokku 2>/dev/null
}

# Returns the running container ID for an app's web process (empty if none).
# Prefers Dokku's container labels (reliable across naming-scheme changes), and
# falls back to the legacy '<app>.web.<n>' name pattern.
app_container_id() {
    local app="$1" cid
    cid=$(docker ps \
            --filter "label=com.dokku.app-name=${app}" \
            --filter "label=com.dokku.process-type=web" \
            --format '{{.ID}}' | head -1)
    if [ -z "$cid" ]; then
        cid=$(docker ps --filter "label=com.dokku.app-name=${app}" \
                       --format '{{.ID}}' | head -1)
    fi
    if [ -z "$cid" ]; then
        cid=$(docker ps --filter "name=^${app}\.web\." --format '{{.ID}}' | head -1)
    fi
    echo "$cid"
}

# Authoritative app state from Dokku itself: prints one of
#   not-deployed | stopped | running | restarting | mixed | unknown
# This is more reliable than guessing from container presence alone, because
# Dokku knows whether a release has ever been deployed for the app.
app_dokku_state() {
    local app="$1" report deployed running
    report=$(docker exec -i dokku dokku ps:report "$app" 2>/dev/null) || { echo unknown; return; }
    deployed=$(printf '%s\n' "$report" | awk -F: '/Deployed:/    {gsub(/ /,"",$2); print tolower($2); exit}')
    running=$(printf  '%s\n' "$report" | awk -F: '/Running:/     {gsub(/ /,"",$2); print tolower($2); exit}')
    if [ "$deployed" != "true" ]; then echo not-deployed; return; fi
    case "$running" in
        true)    echo running ;;
        false)   echo stopped ;;
        mixed)   echo mixed ;;
        *)       echo unknown ;;
    esac
}

# Returns image:tag currently running for an app (empty if not running)
app_image() {
    local app="$1"
    local cid; cid=$(app_container_id "$app")
    [ -z "$cid" ] && return 0
    docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null
}

app_env() {
    local app="$1" key="$2" cid
    cid=$(app_container_id "$app")
    [ -z "$cid" ] && return 0
    docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$cid" 2>/dev/null \
        | awk -F= -v key="$key" '$1==key {sub(/^[^=]*=/,""); print; exit}'
}

app_env_compat() {
    local app="$1" key="$2" legacy="${3:-}" value
    value=$(app_env "$app" "$key")
    if [ -z "$value" ] && [ -n "$legacy" ]; then
        value=$(app_env "$app" "$legacy")
    fi
    printf '%s' "$value"
}

app_label() {
    local app="$1" key="$2" cid
    cid=$(app_container_id "$app")
    [ -z "$cid" ] && return 0
    docker inspect -f "{{index .Config.Labels \"$key\"}}" "$cid" 2>/dev/null \
        | tr -d '\n' | awk '$0 != "<no value>" {print}'
}

app_image_digest() {
    local app="$1" cid image_id ref
    cid=$(app_container_id "$app")
    [ -z "$cid" ] && return 0
    image_id=$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null)
    ref=$(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$image_id" 2>/dev/null \
        | awk -F@ 'NF==2 {print $2; exit}')
    printf '%s' "$ref"
}

app_identity_status() {
    local app="$1" missing="" value declared_digest observed_digest workflow_id
    local version commit channel image_ref source built_at workflow_url
    channel=$(app_env_compat "$app" APP_IMAGE_CHANNEL APP_BUILD_CHANNEL)
    version=$(app_env_compat "$app" APP_IMAGE_VERSION APP_VERSION)
    commit=$(app_env_compat "$app" APP_IMAGE_COMMIT APP_COMMIT)
    image_ref=$(app_env "$app" APP_IMAGE_REF)
    source=$(app_env "$app" APP_SOURCE)
    [ -n "$source" ] || source=$(app_label "$app" org.opencontainers.image.source)
    workflow_id=$(app_env_compat "$app" APP_WORKFLOW_RUN_ID APP_WORKFLOW_RUN)
    workflow_url=$(app_env "$app" APP_WORKFLOW_RUN_URL)
    if [[ "$workflow_id" == https://* || "$workflow_id" == http://* ]]; then
        workflow_url="${workflow_url:-$workflow_id}"
        workflow_id="${workflow_id##*/}"
    fi
    built_at=$(app_env_compat "$app" APP_BUILT_AT APP_CREATED)
    [ -n "$channel" ] || missing="${missing:+$missing, }channel"
    [ -n "$version" ] || missing="${missing:+$missing, }version"
    [ -n "$commit" ] || missing="${missing:+$missing, }commit"
    [ -n "$image_ref" ] || missing="${missing:+$missing, }image_ref"
    [ -n "$source" ] || missing="${missing:+$missing, }source"
    [ -n "$workflow_id" ] || missing="${missing:+$missing, }workflow_run_id"
    [ -n "$built_at" ] || missing="${missing:+$missing, }built_at"
    declared_digest=$(app_env "$app" APP_IMAGE_DIGEST)
    observed_digest=$(app_image_digest "$app")
    [ -n "$declared_digest" ] || missing="${missing:+$missing, }digest"
    [ -n "$observed_digest" ] || missing="${missing:+$missing, }observed_digest"
    if [ -n "$missing" ]; then
        printf 'missing|missing build identity fields: %s' "$missing"
    elif [ "$version" != "dev" ] && ! printf '%s' "$version" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z.-]+)?$'; then
        printf 'invalid|version is not semantic vMAJOR.MINOR.PATCH'
    elif ! printf '%s' "$declared_digest" | grep -Eq '^sha256:[0-9a-fA-F]{64}$'; then
        printf 'invalid|digest is not an immutable sha256 digest'
    elif ! printf '%s' "$workflow_id" | grep -Eq '^[0-9]+$'; then
        printf 'invalid|workflow_run_id is not numeric'
    elif [ -n "$workflow_url" ] && ! printf '%s' "$workflow_url" | grep -Eq '^https?://[^[:space:]]+/actions/runs/[0-9]+$'; then
        printf 'invalid|workflow_run_url is invalid'
    elif ! printf '%s' "$image_ref" | grep -Eq '^[^[:space:]@]+/[^[:space:]@]+:[^[:space:]@]+$'; then
        printf 'invalid|image_ref must include repository and tag'
    elif [ -n "$declared_digest" ] && [ -n "$observed_digest" ] && [ "$declared_digest" != "$observed_digest" ]; then
        printf 'mismatch|recorded digest does not match the running image'
    else
        printf 'verified|'
    fi
}

# Restart count for the app's running container
app_restart_count() {
    local app="$1"
    local cid; cid=$(app_container_id "$app")
    [ -z "$cid" ] && { echo "-"; return; }
    docker inspect -f '{{.RestartCount}}' "$cid" 2>/dev/null
}

# Internal Dokku-network port the app listens on (parsed from `dokku ports:report`)
app_internal_port() {
    local app="$1"
    dokku_app_port "$app"
}

# Host-published ports for the app's container, formatted as "host:container,...".
# Empty when Dokku fronts traffic via its own nginx (the usual case).
app_host_ports() {
    local app="$1"
    local cid; cid=$(app_container_id "$app")
    [ -z "$cid" ] && return 0
    docker inspect -f \
        '{{range $p, $b := .NetworkSettings.Ports}}{{range $b}}{{.HostPort}}->{{$p}} {{end}}{{end}}' \
        "$cid" 2>/dev/null | xargs 2>/dev/null
}

# Dokku's own host-published ports (the entry point all tenant traffic goes through)
dokku_host_ports() {
    docker port dokku 2>/dev/null | awk '{print $1" -> "$3}' | paste -sd ', ' -
}

# What process types does this app expose? (e.g. "web cron worker")
app_process_types() {
    local app="$1"
    docker exec -i dokku dokku ps:scale "$app" 2>/dev/null \
        | awk 'NR>2 && $1!="" {print $1}' | xargs 2>/dev/null
}

# Detect role from app name suffix; falls back to "app" for arbitrary names.
app_kind() {
    case "$1" in
        *-backend)  echo backend  ;;
        *-frontend) echo frontend ;;
        *)          echo app      ;;
    esac
}

# Tenant inferred from app name ("-backend"/"-frontend" stripped if present).
app_tenant() {
    local app="$1"
    case "$app" in
        *-backend)  echo "${app%-backend}"  ;;
        *-frontend) echo "${app%-frontend}" ;;
        *)          echo "$app" ;;
    esac
}

# HTTP probe inside the dokku container against the app's web service
app_http_probe() {
    local app="$1"
    local path="${2:-/}" port
    port="$(dokku_app_port "$app")"
    docker exec -i "${DOKKU_CONTAINER:-dokku}" bash -lc \
        "curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://${app}.web:${port}${path}" \
        2>/dev/null || echo "000"
}

app_http_probe_detail() {
    local app="$1" path="${2:-/}" port
    port="$(dokku_app_port "$app")"
    docker exec -i "${DOKKU_CONTAINER:-dokku}" bash -lc \
        "curl -sS -o /dev/null -w '%{http_code}\t%{errormsg}' --max-time 5 http://${app}.web:${port}${path}" \
        2>/dev/null || true
}

external_http_probe_detail() {
    local domain="$1" path="${2:-/}" scheme="https"
    [ -z "$domain" ] && { printf '000\tno Dokku route is configured'; return; }
    [[ "$domain" == *"://"* ]] && scheme="" || true
    if [ -n "$scheme" ]; then
        domain="${scheme}://${domain}"
    fi
    curl -k -sS -o /dev/null -w '%{http_code}\t%{errormsg}' --max-time 5 "${domain}${path}" 2>&1 || true
}

probe_code() {
    local result="$1" code="${result%%$'\t'*}"
    [ "${#code}" -eq 3 ] && printf '%s' "$code" || printf '000'
}

probe_reason() {
    local result="$1"
    if [[ "$result" == *$'\t'* ]]; then
        printf '%s' "${result#*$'\t'}"
    else
        printf 'probe did not return an HTTP response'
    fi
}

probe_status() {
    case "$1" in
        2*|3*) printf 'healthy' ;;
        000)   printf 'unavailable' ;;
        *)     printf 'unhealthy' ;;
    esac
}

json_escape() {
    local value="${1:-}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\n'/\\n}"
    printf '%s' "$value"
}

# Per-tenant pin from master DB (echoes "<backend>|<frontend>|<enabled>")
tenant_pin() {
    local name="$1"
    if ! command -v mysql &>/dev/null && [ "${_MYSQL_VIA:-host}" = "docker" ]; then
        echo "|"; return
    fi
    run_mysql -N -B -e \
        "SELECT IFNULL(backend_image,''), IFNULL(frontend_image,''), enabled
           FROM \`${MYSQL_MASTER_DB}\`.tenant
          WHERE name='${name//\'/}' LIMIT 1;" 2>/dev/null \
        | awk -F'\t' '{printf "%s|%s|%s", $1, $2, $3}'
}

# Echoes the verified identity for the app kind:
# image_ref|digest|version|commit|status
tenant_provenance() {
    local name="$1" kind="$2" p
    case "$kind" in backend|frontend) p="$kind" ;; *) echo "||||"; return ;; esac
    if ! command -v mysql &>/dev/null && [ "${_MYSQL_VIA:-host}" = "docker" ]; then
        echo "||||"
        return
    fi
    run_mysql -N -B -e \
        "SELECT IFNULL(${p}_image_ref,''), IFNULL(${p}_image_digest,''),
                IFNULL(${p}_version,''), IFNULL(${p}_commit,''),
                IFNULL(${p}_deployment_status,'unknown')
           FROM \`${MYSQL_MASTER_DB}\`.tenant
          WHERE name='${name//\'/}' LIMIT 1;" 2>/dev/null \
        | awk -F'\t' '{printf "%s|%s|%s|%s|%s", $1,$2,$3,$4,$5}'
}

cron_has_autopull() {
    crontab -l 2>/dev/null | grep -q 'auto-pull.sh' && echo "yes" || echo "no"
}

colorize_state() {
    case "$1" in
        running)                       echo "${G}running${N}" ;;
        restarting|created|mixed)      echo "${Y}$1${N}" ;;
        exited|dead|paused|stopped)    echo "${R}$1${N}" ;;
        not-deployed)                  echo "${Y}not-deployed${N}" ;;
        missing|unknown|"")            echo "${R}${1:-missing}${N}" ;;
        *)                             echo "$1" ;;
    esac
}

colorize_http() {
    local code="$1"
    case "$code" in
        2*|3*) echo "${G}${code}${N}" ;;
        000)   echo "${R}no-resp${N}" ;;
        *)     echo "${Y}${code}${N}" ;;
    esac
}

json_auto_pull_field() {
    printf '"auto_pull_cron":{"state":"%s","diagnostic":"%s"}' \
        "$AUTO_PULL_STATE" "$(json_escape "$AUTO_PULL_DIAGNOSTIC")"
}

# ---- One pass of the report --------------------------------------------------
render_once() {
    local dstate; dstate=$(dokku_state)
    local dports; dports=$(dokku_host_ports)
    if ! $JSON; then
        echo ""
        echo "${B}===========================================================${N}"
        echo "${B}  Dokku Status — *.${BASE_DOMAIN}   $(date '+%F %T %Z')${N}"
        echo "${B}===========================================================${N}"
        printf "  Dokku container : %s\n" "$(colorize_state "$dstate")"
        printf "  Dokku host ports: %s\n" "${dports:-<none>}"
        [ -n "$(tenant_name_prefix)" ] && printf "  Tenant prefix   : %s\n" "$(tenant_name_prefix)"
        printf "  Auto-pull cron  : %s — %s\n" "$AUTO_PULL_STATE" "$AUTO_PULL_DIAGNOSTIC"
        printf "  Repo commit     : %s (%s)\n" \
            "$(git -c safe.directory='*' -C "$SCRIPT_DIR/.." rev-parse --short HEAD 2>/dev/null || echo unknown)" \
            "$(git -c safe.directory='*' -C "$SCRIPT_DIR/.." branch --show-current 2>/dev/null || echo unknown)"
        echo ""
    fi

    if [ "$dstate" != "running" ]; then
        $JSON || echo "${R}Dokku is not running — no app data to report.${N}"
        $JSON && printf '{"dokku":"%s",%s,"apps":[]}\n' "$dstate" "$(json_auto_pull_field)"
        return
    fi

    # All Dokku apps (one per line). Strip the "=====> My Apps" header by keeping
    # only lines that look like a Dokku app name (lowercase, digits, hyphens).
    local apps; apps=$(docker exec -i dokku dokku --quiet apps:list 2>/dev/null \
                       | grep -E '^[a-z0-9][a-z0-9-]*$' || true)

    if [ -n "$(tenant_name_prefix)" ]; then
        apps=$(while IFS= read -r app; do
            tenant="$(app_tenant "$app")"
            tenant_in_scope "$tenant" && printf '%s\n' "$app"
        done <<< "$apps")
    fi

    if [ -n "$TENANT_FILTER" ]; then
        apps=$(printf '%s\n' "$apps" \
               | awk -v t="$TENANT_FILTER" '$0==t || $0==t"-backend" || $0==t"-frontend"')
    fi

    if [ -z "$apps" ]; then
        if $JSON; then
            printf '{"dokku":"running","host_ports":"%s",%s,"apps":[]}\n' \
                "$dports" "$(json_auto_pull_field)"
        else
            echo "  ${Y}No Dokku apps registered.${N}"
            echo "  ${D}Raw 'dokku apps:list' output:${N}"
            docker exec -i dokku dokku apps:list 2>&1 | sed 's/^/    /' || true
            echo ""
            echo "  Hints:"
            echo "    • Did setup-dev-tenant.sh complete?  sudo bash scripts/setup-dev-tenant.sh"
            echo "    • Create one manually:                 dokku apps:create dev-backend"
        fi
        return
    fi

    if $JSON; then
        printf '{"dokku":"running","host_ports":"%s",%s,"apps":[' "$dports" "$(json_auto_pull_field)"
    else
        printf "  ${D}%-18s %-8s %-9s %-3s %-5s %-6s %-7s %-32s %s${N}\n" \
            "APP" "ROLE" "STATE" "RST" "HTTP" "INTPORT" "PROCS" "IMAGE (running)" "DOMAINS"
    fi

    local first=true
    while IFS= read -r app; do
        [ -z "$app" ] && continue
        local tenant; tenant=$(app_tenant "$app")
        local kind;   kind=$(app_kind "$app")
        local cid;    cid=$(app_container_id "$app")

        local state rcount="-" image="-" probe="000" probe_reason="container is not running" path="/"
        local internal_status="not-checked" external_code="000" external_status="not-checked"
        local external_reason="container is not running" identity_status="missing" identity_reason="container has no build identity"
        # Ask Dokku first; only fall back to docker inspect to refine 'running'
        # into 'restarting'/'exited' when the container is mid-flap.
        state=$(app_dokku_state "$app")
        if [ -n "$cid" ]; then
            local cstate; cstate=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || echo "")
            case "$cstate" in
                restarting|exited|dead|paused) state="$cstate" ;;
            esac
            rcount=$(app_restart_count "$app")
            image=$(app_image "$app")
        fi
        local intport;   intport=$(app_internal_port "$app")
        local hostports; hostports=$(app_host_ports "$app")
        local procs;     procs=$(app_process_types "$app")
        [ "$kind" = "backend" ] && path="/healthz"
        local domains; domains=$(docker exec -i dokku dokku domains:report "$app" --domains-app-vhosts 2>/dev/null | tr -s ' ')
        if [ "$state" = "running" ]; then
            local internal_detail; internal_detail=$(app_http_probe_detail "$app" "$path")
            probe=$(probe_code "$internal_detail")
            probe_reason=$(probe_reason "$internal_detail")
            internal_status=$(probe_status "$probe")
            local external_detail; external_detail=$(external_http_probe_detail "${domains%% *}" "$path")
            external_code=$(probe_code "$external_detail")
            external_reason=$(probe_reason "$external_detail")
            external_status=$(probe_status "$external_code")
        fi
        if [ -n "$cid" ]; then
            local identity_detail; identity_detail=$(app_identity_status "$app")
            identity_status="${identity_detail%%|*}"
            identity_reason="${identity_detail#*|}"
        fi
        local liveness_status="unknown"
        case "$state" in
            running) liveness_status="healthy" ;;
            not-deployed|unknown|"") liveness_status="unknown" ;;
            *) liveness_status="unhealthy" ;;
        esac
        local image_ref image_digest version commit short_commit channel workflow_id workflow_url built_at deployed_at
        image_ref=$(app_env "$app" APP_IMAGE_REF)
        image_digest=$(app_env "$app" APP_IMAGE_DIGEST)
        [ -n "$image_digest" ] || image_digest=$(app_image_digest "$app")
        version=$(app_env_compat "$app" APP_IMAGE_VERSION APP_VERSION)
        commit=$(app_env_compat "$app" APP_IMAGE_COMMIT APP_COMMIT)
        short_commit=$(app_env "$app" APP_IMAGE_COMMIT_SHORT)
        [ -n "$short_commit" ] || short_commit="${commit:0:7}"
        channel=$(app_env_compat "$app" APP_IMAGE_CHANNEL APP_BUILD_CHANNEL)
        workflow_id=$(app_env_compat "$app" APP_WORKFLOW_RUN_ID APP_WORKFLOW_RUN)
        workflow_url=$(app_env "$app" APP_WORKFLOW_RUN_URL)
        built_at=$(app_env_compat "$app" APP_BUILT_AT APP_CREATED)
        deployed_at=$(app_env "$app" APP_DEPLOYED_AT)

        if $JSON; then
            $first || printf ','
            first=false
            local pin; pin=$(tenant_pin "$tenant")
            local pin_be; pin_be="${pin%%|*}"
            local rest="${pin#*|}"
            local pin_fe; pin_fe="${rest%%|*}"
            local enabled="${rest##*|}"
            local provenance; provenance=$(tenant_provenance "$tenant" "$kind")
            local p_ref="${provenance%%|*}" p_rest="${provenance#*|}"
            local p_digest="${p_rest%%|*}"; p_rest="${p_rest#*|}"
            local p_version="${p_rest%%|*}"; p_rest="${p_rest#*|}"
            local p_commit="${p_rest%%|*}"; local p_status="${p_rest#*|}"
            printf '{"app":"%s","tenant":"%s","role":"%s","state":"%s","restarts":"%s","http":"%s","http_reason":"%s","internal_port":"%s","host_ports":"%s","processes":"%s","image":"%s","domains":"%s","pinned_backend":"%s","pinned_frontend":"%s","enabled":"%s","health":{"liveness":{"status":"%s","reason":"%s"},"internal":{"status":"%s","http_code":"%s","reason":"%s"},"external":{"status":"%s","http_code":"%s","reason":"%s"}},"identity":{"channel":"%s","version":"%s","commit":"%s","short_commit":"%s","image_ref":"%s","digest":"%s","workflow_run_id":"%s","workflow_run_url":"%s","built_at":"%s","deployed_at":"%s","status":"%s","reason":"%s"},"provenance":{"ref":"%s","digest":"%s","version":"%s","commit":"%s","status":"%s"}}' \
                "$(json_escape "$app")" "$(json_escape "$tenant")" "$(json_escape "$kind")" "$(json_escape "$state")" "$(json_escape "$rcount")" "$(json_escape "$probe")" "$(json_escape "$probe_reason")" "$(json_escape "$intport")" "$(json_escape "$hostports")" "$(json_escape "$procs")" "$(json_escape "$image")" "$(json_escape "$domains")" "$(json_escape "$pin_be")" "$(json_escape "$pin_fe")" "$(json_escape "$enabled")" \
                "$(json_escape "$liveness_status")" "$(json_escape "$probe_reason")" "$(json_escape "$internal_status")" "$(json_escape "$probe")" "$(json_escape "$probe_reason")" "$(json_escape "$external_status")" "$(json_escape "$external_code")" "$(json_escape "$external_reason")" \
                "$(json_escape "$channel")" "$(json_escape "$version")" "$(json_escape "$commit")" "$(json_escape "$short_commit")" "$(json_escape "$image_ref")" "$(json_escape "$image_digest")" "$(json_escape "$workflow_id")" "$(json_escape "$workflow_url")" "$(json_escape "$built_at")" "$(json_escape "$deployed_at")" "$(json_escape "$identity_status")" "$(json_escape "$identity_reason")" \
                "$(json_escape "$p_ref")" "$(json_escape "$p_digest")" "$(json_escape "$p_version")" "$(json_escape "$p_commit")" "$(json_escape "$p_status")"
        else
            printf "  %-18s %-8s %s %-3s %s %-6s %-7s %-32s %s\n" \
                "$app" "$kind" "$(printf '%-9s' "$(colorize_state "$state")")" \
                "$rcount" \
                "$(printf '%-5s' "$(colorize_http "$probe")")" \
                "${intport:--}" "${procs:--}" "${image:--}" "${domains:--}"
            [ "$probe" = "000" ] && printf "  ${D}%-18s   internal probe: %s${N}\n" "" "${probe_reason:-no HTTP response}"
            [ "$external_code" = "000" ] && printf "  ${D}%-18s   external probe: %s${N}\n" "" "${external_reason:-no HTTP response}"
            [ "$identity_status" != "verified" ] && printf "  ${D}%-18s   provenance: %s${N}\n" "" "${identity_reason:-unverified}"
            [ -n "${image_ref:-}" ] && printf "  ${D}%-18s   source image: %s @ %s${N}\n" "" "$image_ref" "${image_digest:--}"
            [ -n "$hostports" ] && printf "  ${D}%-18s   host-published: %s${N}\n" "" "$hostports"
        fi

        if ! $JSON && [ -n "$TENANT_FILTER" ]; then
            local pin; pin=$(tenant_pin "$tenant")
            local pin_be; pin_be="${pin%%|*}"
            local rest="${pin#*|}"
            local pin_fe; pin_fe="${rest%%|*}"
            local enabled="${rest##*|}"
            echo ""
            echo "  ${D}Pinned in master DB :${N} backend=${pin_be:-<unset>} frontend=${pin_fe:-<unset>} enabled=${enabled:-?}"
            local provenance; provenance=$(tenant_provenance "$tenant" "$kind")
            echo "  ${D}Verified provenance :${N} ${provenance:-<unavailable>}"
            echo ""
            echo "  ${D}Recent ${app} logs:${N}"
            docker exec -i dokku dokku logs "$app" --tail 15 2>/dev/null | sed 's/^/    /' || true
        fi
    done <<< "$apps"

    $JSON && printf ']}\n'
    $JSON || echo ""
}

# ---- Main --------------------------------------------------------------------
if $WATCH; then
    while :; do
        clear
        render_once
        sleep 5
    done
else
    render_once
fi
