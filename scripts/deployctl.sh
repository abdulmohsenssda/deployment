#!/usr/bin/env bash
# deployctl.sh - one command for Dokku tenant operations.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROGRAM="${0##*/}"
CONFIG_FILE="${CONFIG_FILE:-}"
PLAN=false

usage() {
    cat <<'USAGE'
Usage:
  deployctl [global flags] <area> <command> [args]

Global flags:
  --config <file>  Forward a config.env path to commands that support it
  --plan           Print the underlying script command without running it
  -h, --help       Show this help

Areas:
  tenant create <name> [flags]       Provision backend, frontend, storage, DB
  tenant update <name> [flags]       Change image/env/scale or restart
  tenant remove <name> [flags]       Delete a tenant
  tenant status [name] [flags]       Show fleet or tenant health
  tenant logs [name] [flags]         Tail tenant logs
  tenant backup [name|--all]         Dump tenant data
  tenant restore <name> --from <id>  Restore/rollback a tenant to a backup
  tenant backups <list|delete|prune> Manage backup sets (protect/verify/prune)
  tenant rollback <name> [flags]     Roll back to a previous image
  tenant pin [name] [flags]          Pin or list desired images
  tenant init-db <name> [flags]      Initialize schema and seed users
  tenant cleanup <name> [flags]      Repair/remove a half-created tenant

  fleet status [flags]               Full health overview
  fleet sync <image> [flags]         Roll an image to tenants
  fleet logs [flags]                 Aggregate logs
  fleet backup                       Back up every tenant
  fleet backups <list|prune>         Manage backups across the fleet
  fleet auto-pull [flags]            Run one auto-pull cycle

  stack restart [flags]              Restart Dokku/dashboard stack
  setup all|dokku|nats|dev-tenant    Bootstrap server pieces
  db verify                          Check MySQL connectivity
  dokku fix-hostname|discover-nginx|traffic
  webhook serve|tls
  cleanup old-files

Examples:
  deployctl tenant create acme --backend-image repo/ifritah-api:v1 --frontend-image repo/ifritah-web:v1
  deployctl tenant update acme --restart
  deployctl fleet sync repo/ifritah-api:v2 --type backend --tenant acme
  deployctl --plan --config /opt/deployment/config.prod.env tenant status acme --json
USAGE
}

die() {
    echo "$PROGRAM: $*" >&2
    exit 1
}

need_arg() {
    local value="${1:-}"
    local label="$2"
    [ -n "$value" ] || die "missing $label"
}

script_accepts_config() {
    case "$1" in
        auto-pull.sh|backup-tenant.sh|cleanup-broken-tenant.sh|create-tenant.sh|deploy-all.sh|init-tenant-db.sh|list-tenants.sh|manage-backups.sh|remove-tenant.sh|restore-tenant.sh|rollback-tenant.sh|set-tenant-image.sh|setup-dev-tenant.sh|setup.sh|status.sh|update-tenant.sh|webhook-server.sh)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

print_plan() {
    local script="$1"
    shift
    printf 'bash %q' "scripts/$script"
    local arg
    for arg in "$@"; do
        printf ' %q' "$arg"
    done
    printf '\n'
}

run_script() {
    local script="$1"
    shift
    [ -f "$SCRIPT_DIR/$script" ] || die "unknown script: $script"

    local args=("$@")
    if [ -n "$CONFIG_FILE" ] && script_accepts_config "$script"; then
        export CONFIG_FILE
        args+=(--config "$CONFIG_FILE")
    fi

    if $PLAN; then
        print_plan "$script" "${args[@]}"
        return 0
    fi

    exec bash "$SCRIPT_DIR/$script" "${args[@]}"
}

optional_name_arg() {
    if [ "$#" -gt 0 ] && [[ "$1" != -* ]]; then
        printf '%s' "$1"
    fi
}

tenant_cmd() {
    local verb="${1:-}"
    [ -n "$verb" ] || die "tenant command required"
    shift || true

    case "$verb" in
        create|new)
            local name="${1:-}"; need_arg "$name" "tenant name"; shift
            run_script create-tenant.sh "$name" "$@"
            ;;
        update|sync)
            local name="${1:-}"; need_arg "$name" "tenant name"; shift
            run_script update-tenant.sh "$name" "$@"
            ;;
        remove|delete|rm)
            local name="${1:-}"; need_arg "$name" "tenant name"; shift
            run_script remove-tenant.sh "$name" "$@"
            ;;
        status)
            local name
            name="$(optional_name_arg "$@")"
            if [ -n "$name" ]; then
                shift
                run_script status.sh --tenant "$name" "$@"
                return
            fi
            run_script status.sh "$@"
            ;;
        list|ls)
            run_script list-tenants.sh "$@"
            ;;
        logs|log)
            local name
            name="$(optional_name_arg "$@")"
            if [ -n "$name" ]; then
                shift
                run_script tail-logs.sh --tenant "$name" "$@"
                return
            fi
            run_script tail-logs.sh "$@"
            ;;
        backup)
            run_script backup-tenant.sh "$@"
            ;;
        restore)
            local name="${1:-}"; need_arg "$name" "tenant name"; shift
            run_script restore-tenant.sh "$name" "$@"
            ;;
        backups)
            run_script manage-backups.sh "$@"
            ;;
        rollback)
            local name="${1:-}"; need_arg "$name" "tenant name"; shift
            run_script rollback-tenant.sh "$name" "$@"
            ;;
        pin|image)
            run_script set-tenant-image.sh "$@"
            ;;
        init-db|db-init)
            local name="${1:-}"; need_arg "$name" "tenant name"; shift
            run_script init-tenant-db.sh "$name" "$@"
            ;;
        cleanup|repair)
            local name="${1:-}"; need_arg "$name" "tenant name"; shift
            run_script cleanup-broken-tenant.sh "$name" "$@"
            ;;
        *)
            die "unknown tenant command: $verb"
            ;;
    esac
}

fleet_cmd() {
    local verb="${1:-status}"
    shift || true

    case "$verb" in
        status)
            run_script status.sh "$@"
            ;;
        list|ls)
            run_script list-tenants.sh "$@"
            ;;
        sync|deploy|rollout)
            local image="${1:-}"; need_arg "$image" "image"; shift
            run_script deploy-all.sh "$image" "$@"
            ;;
        logs|log)
            run_script tail-logs.sh "$@"
            ;;
        backup)
            run_script backup-tenant.sh --all "$@"
            ;;
        backups)
            run_script manage-backups.sh "$@"
            ;;
        auto-pull|pull)
            run_script auto-pull.sh "$@"
            ;;
        *)
            die "unknown fleet command: $verb"
            ;;
    esac
}

stack_cmd() {
    local verb="${1:-status}"
    shift || true
    case "$verb" in
        status) run_script status.sh "$@" ;;
        restart) run_script restart-stack.sh "$@" ;;
        *) die "unknown stack command: $verb" ;;
    esac
}

setup_cmd() {
    local target="${1:-all}"
    shift || true
    case "$target" in
        all) run_script setup.sh "$@" ;;
        dokku) run_script setup-dokku.sh "$@" ;;
        nats) run_script setup-nats.sh "$@" ;;
        dev-tenant|tenant) run_script setup-dev-tenant.sh "$@" ;;
        *) die "unknown setup target: $target" ;;
    esac
}

db_cmd() {
    local verb="${1:-verify}"
    shift || true
    case "$verb" in
        verify|check) run_script verify-mysql.sh "$@" ;;
        init)
            local name="${1:-}"; need_arg "$name" "tenant name"; shift
            run_script init-tenant-db.sh "$name" "$@"
            ;;
        *) die "unknown db command: $verb" ;;
    esac
}

dokku_cmd() {
    local verb="${1:-}"
    [ -n "$verb" ] || die "dokku command required"
    shift || true
    case "$verb" in
        fix-hostname|hostname) run_script fix-dokku-hostname.sh "$@" ;;
        discover-nginx|nginx) run_script discover-dokku-nginx.sh "$@" ;;
        traffic|watch-traffic) run_script watch-dokku-traffic.sh "$@" ;;
        *) die "unknown dokku command: $verb" ;;
    esac
}

webhook_cmd() {
    local verb="${1:-serve}"
    shift || true
    case "$verb" in
        serve|server) run_script webhook-server.sh "$@" ;;
        tls) run_script webhook-tls.sh "$@" ;;
        *) die "unknown webhook command: $verb" ;;
    esac
}

cleanup_cmd() {
    local target="${1:-old-files}"
    shift || true
    case "$target" in
        old-files|legacy) run_script cleanup-old-files.sh "$@" ;;
        tenant)
            local name="${1:-}"; need_arg "$name" "tenant name"; shift
            run_script cleanup-broken-tenant.sh "$name" "$@"
            ;;
        *) die "unknown cleanup target: $target" ;;
    esac
}

legacy_script_cmd() {
    local script="${1:-}"
    need_arg "$script" "script name"
    shift
    case "$script" in
        *.sh) ;;
        *) script="$script.sh" ;;
    esac
    case "$script" in
        */*|..*) die "script name must be a file in scripts/: $script" ;;
    esac
    run_script "$script" "$@"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --config)
            CONFIG_FILE="${2:-}"
            need_arg "$CONFIG_FILE" "config path"
            shift 2
            ;;
        --plan)
            PLAN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            break
            ;;
    esac
done

cmd="${1:-}"
[ -n "$cmd" ] || { usage; exit 0; }
shift || true

case "$cmd" in
    tenant) tenant_cmd "$@" ;;
    fleet) fleet_cmd "$@" ;;
    stack) stack_cmd "$@" ;;
    setup) setup_cmd "$@" ;;
    db) db_cmd "$@" ;;
    dokku) dokku_cmd "$@" ;;
    webhook) webhook_cmd "$@" ;;
    cleanup) cleanup_cmd "$@" ;;
    script) legacy_script_cmd "$@" ;;
    status) fleet_cmd status "$@" ;;
    logs|log) fleet_cmd logs "$@" ;;
    sync|deploy) fleet_cmd sync "$@" ;;
    backup) fleet_cmd backup "$@" ;;
    help) usage ;;
    *) die "unknown area: $cmd" ;;
esac