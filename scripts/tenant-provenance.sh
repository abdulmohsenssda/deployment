#!/usr/bin/env bash
# Shared tenant deployment provenance helpers.
#
# BuildIdentity is deliberately kept in the deployment layer so a deployment
# can fail closed even when an image tag was moved or an application reports a
# different build than the image that was inspected.

provenance_label() {
    local image="$1" key="$2" value=""
    value="$(docker image inspect --format="{{index .Config.Labels \"${key}\"}}" "$image" 2>/dev/null || true)"
    if [ -z "$value" ]; then
        value="$(docker inspect --format="{{index .Config.Labels \"${key}\"}}" "$image" 2>/dev/null || true)"
    fi
    printf '%s' "$value" | tr -d '\n'
}

provenance_first_label() {
    local image="$1" key value
    shift
    for key in "$@"; do
        value="$(provenance_label "$image" "$key")"
        if [ -n "$value" ] && [ "$value" != "<no value>" ]; then
            printf '%s' "$value"
            return 0
        fi
    done
    return 1
}

provenance_repo_digest() {
    local image="$1" repo digest line
    if [[ "$image" == *@sha256:* ]]; then
        digest="${image##*@}"
        printf '%s\t%s' "$image" "$digest"
        return 0
    fi

    if [[ "$image" == */* ]]; then
        repo="${image%:*}"
    else
        repo="library/${image%:*}"
    fi
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [[ "$line" == "$repo"@sha256:* ]]; then
            digest="${line##*@}"
            printf '%s\t%s' "$line" "$digest"
            return 0
        fi
        if [[ "$line" == *@sha256:* && -z "${digest:-}" ]]; then
            digest="${line##*@}"
            printf '%s\t%s' "$line" "$digest"
            return 0
        fi
    done < <(docker image inspect --format='{{range .RepoDigests}}{{println .}}{{end}}' "$image" 2>/dev/null || true)

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [[ "$line" == *@sha256:* ]]; then
            digest="${line##*@}"
            printf '%s\t%s' "$line" "$digest"
            return 0
        fi
    done < <(docker inspect --format='{{range .RepoDigests}}{{println .}}{{end}}' "$image" 2>/dev/null || true)
    return 1
}

provenance_override_enabled() {
    [ "${TENANT_PROVENANCE_OVERRIDE:-0}" = "1" ] || return 1
    case "${DEPLOY_ENV:-${ZATCA_ENV:-production}}" in
        dev|development|test|testing|sandbox|simulation|qa) return 0 ;;
        *) return 1 ;;
    esac
}

provenance_identity_reset() {
    BUILD_CHANNEL=""
    BUILD_VERSION=""
    BUILD_COMMIT=""
    BUILD_COMMIT_SHORT=""
    BUILD_WORKFLOW_RUN_ID=""
    BUILD_WORKFLOW_RUN_URL=""
    BUILD_WORKFLOW_RUN=""
    BUILD_IMAGE_REF=""
    BUILD_SOURCE=""
    BUILD_DIGEST=""
    BUILD_RESOLVED_REF=""
    BUILD_BUILT_AT=""
}

# Resolve a tag to a full digest and populate the approved BuildIdentity
# fields. Output is intentionally quiet; callers can safely use this in an
# `if` condition and record a useful failure themselves.
resolve_build_identity() {
    local image="$1" digest_info digest_label
    provenance_identity_reset

    BUILD_CHANNEL="$(provenance_first_label "$image" \
        com.ifritah.build.channel org.ifritah.build.channel \
        org.opencontainers.image.channel || true)"
    BUILD_VERSION="$(provenance_first_label "$image" \
        org.opencontainers.image.version || true)"
    BUILD_COMMIT="$(provenance_first_label "$image" \
        org.opencontainers.image.revision com.ifritah.build.commit || true)"
    BUILD_WORKFLOW_RUN_ID="$(provenance_first_label "$image" \
        com.ifritah.build.workflow_run_id com.ifritah.build.workflow-run-id \
        com.ifritah.build.workflow_run com.ifritah.build.workflow-run \
        org.ifritah.build.workflow_run_id org.ifritah.build.workflow-run-id \
        org.ifritah.build.workflow_run org.ifritah.build.workflow-run \
        org.opencontainers.image.workflow.run || true)"
    BUILD_WORKFLOW_RUN_URL="$(provenance_first_label "$image" \
        com.ifritah.build.workflow_run_url com.ifritah.build.workflow-run-url \
        org.ifritah.build.workflow_run_url org.ifritah.build.workflow-run-url || true)"
    if [[ "$BUILD_WORKFLOW_RUN_ID" == https://* || "$BUILD_WORKFLOW_RUN_ID" == http://* ]]; then
        BUILD_WORKFLOW_RUN_URL="${BUILD_WORKFLOW_RUN_URL:-$BUILD_WORKFLOW_RUN_ID}"
        BUILD_WORKFLOW_RUN_ID="${BUILD_WORKFLOW_RUN_URL##*/}"
    fi
    BUILD_WORKFLOW_RUN="$BUILD_WORKFLOW_RUN_ID"
    BUILD_IMAGE_REF="$(provenance_first_label "$image" \
        com.ifritah.build.image_ref com.ifritah.build.image-ref \
        org.ifritah.build.image_ref org.ifritah.build.image-ref \
        org.opencontainers.image.ref.name || true)"
    BUILD_SOURCE="$(provenance_first_label "$image" \
        org.opencontainers.image.source || true)"
    BUILD_BUILT_AT="$(provenance_first_label "$image" \
        org.opencontainers.image.created com.ifritah.build.built_at \
        com.ifritah.build.built-at org.ifritah.build.built_at || true)"

    if [ -n "$BUILD_COMMIT" ]; then
        BUILD_COMMIT_SHORT="$(provenance_first_label "$image" \
            com.ifritah.build.commit_short com.ifritah.build.commit-short \
            org.ifritah.build.commit_short org.ifritah.build.commit-short || true)"
        BUILD_COMMIT_SHORT="${BUILD_COMMIT_SHORT:-${BUILD_COMMIT:0:7}}"
    fi

    digest_info="$(provenance_repo_digest "$image" || true)"
    BUILD_RESOLVED_REF="${digest_info%%$'\t'*}"
    BUILD_DIGEST="${digest_info#*$'\t'}"
    digest_label="$(provenance_first_label "$image" \
        com.ifritah.build.digest org.ifritah.build.digest || true)"

    if [ -z "$BUILD_CHANNEL" ] || [ -z "$BUILD_VERSION" ] ||
       [ -z "$BUILD_COMMIT" ] || [ -z "$BUILD_COMMIT_SHORT" ] ||
       [ -z "$BUILD_WORKFLOW_RUN_ID" ] || [ -z "$BUILD_IMAGE_REF" ] ||
       [ -z "$BUILD_SOURCE" ] ||
       [ -z "$BUILD_BUILT_AT" ] || [ -z "$BUILD_DIGEST" ] ||
       ! printf '%s' "$BUILD_VERSION" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z.-]+)?$' ||
       ! printf '%s' "$BUILD_DIGEST" | grep -Eq '^sha256:[0-9a-fA-F]{64}$' ||
       ! printf '%s' "$BUILD_WORKFLOW_RUN_ID" | grep -Eq '^[0-9]+$' ||
       ! printf '%s' "$BUILD_IMAGE_REF" | grep -Eq '^[^[:space:]@]+/[^[:space:]@]+:[^[:space:]@]+$' ||
       { [ -n "$BUILD_WORKFLOW_RUN_URL" ] &&
         ! printf '%s' "$BUILD_WORKFLOW_RUN_URL" | grep -Eq '^https?://[^[:space:]]+/actions/runs/[0-9]+$'; }; then
        if provenance_override_enabled; then
            echo "[!] Non-production provenance override enabled; image identity is incomplete." >&2
        else
            return 1
        fi
    fi

    if [ -n "$digest_label" ] && [ "$digest_label" != "$BUILD_DIGEST" ]; then
        if ! provenance_override_enabled; then
            return 1
        fi
        echo "[!] Non-production provenance override enabled; image digest label disagrees." >&2
    fi

    if [ -n "$BUILD_IMAGE_REF" ] &&
       [ "$BUILD_IMAGE_REF" != "$image" ] &&
       [ "$BUILD_IMAGE_REF" != "$BUILD_RESOLVED_REF" ]; then
        if ! provenance_override_enabled; then
            return 1
        fi
        echo "[!] Non-production provenance override enabled; image ref label disagrees." >&2
    fi

    return 0
}

provenance_identity_tsv() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
        "$BUILD_CHANNEL" "$BUILD_VERSION" "$BUILD_COMMIT" "$BUILD_COMMIT_SHORT" \
        "$BUILD_WORKFLOW_RUN_ID" "$BUILD_WORKFLOW_RUN_URL" "$BUILD_IMAGE_REF" \
        "$BUILD_DIGEST" "$BUILD_BUILT_AT"
}

provenance_json_field() {
    local json="$1" key="$2" value
    value="$(printf '%s' "$json" | sed -nE \
        "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" | head -n1)"
    if [ -z "$value" ]; then
        value="$(printf '%s' "$json" | sed -nE \
            "s/.*\"${key}\"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p" | head -n1)"
    fi
    printf '%s' "$value"
}

app_version_response() {
    local app="$1" container="${DOKKU_CONTAINER:-dokku}" response
    response="$(docker exec -i "$container" sh -lc \
        "curl -fsS --max-time 10 http://${app}.web/version" 2>/dev/null || true)"
    if [ -z "$response" ]; then
        response="$(docker exec -i "$container" sh -lc \
            "wget -qO- -T 10 http://${app}.web/version" 2>/dev/null || true)"
    fi
    [ -n "$response" ] || return 1
    printf '%s' "$response"
}

verify_runtime_identity() {
    local app="$1" expected_version="$2" expected_commit="$3"
    local expected_digest="$4" expected_ref="$5" expected_channel="$6"
    local expected_workflow_id="$7" expected_workflow_url="$8" expected_built_at="$9" response
    local actual_version actual_commit actual_digest actual_ref actual_channel
    local actual_workflow_id actual_workflow_url actual_built_at

    if provenance_override_enabled; then
        echo "[!] Non-production provenance override enabled; skipping strict /version identity check." >&2
        return 0
    fi

    response="$(app_version_response "$app" || true)"
    [ -n "$response" ] || return 1

    actual_version="$(provenance_json_field "$response" version)"
    actual_commit="$(provenance_json_field "$response" commit)"
    [ -n "$actual_commit" ] || actual_commit="$(provenance_json_field "$response" revision)"
    actual_digest="$(provenance_json_field "$response" digest)"
    [ -n "$actual_digest" ] || actual_digest="$(provenance_json_field "$response" image_digest)"
    actual_ref="$(provenance_json_field "$response" image_ref)"
    actual_channel="$(provenance_json_field "$response" channel)"
    actual_workflow_id="$(provenance_json_field "$response" workflow_run_id)"
    [ -n "$actual_workflow_id" ] || actual_workflow_id="$(provenance_json_field "$response" workflow_run)"
    [ -n "$actual_workflow_id" ] || actual_workflow_id="$(provenance_json_field "$response" workflow)"
    actual_workflow_url="$(provenance_json_field "$response" workflow_run_url)"
    [ -n "$actual_workflow_url" ] || actual_workflow_url="$(provenance_json_field "$response" workflow_url)"
    actual_built_at="$(provenance_json_field "$response" built_at)"
    [ -n "$actual_built_at" ] || actual_built_at="$(provenance_json_field "$response" created)"

    [ "$actual_version" = "$expected_version" ] &&
        [ "$actual_commit" = "$expected_commit" ] &&
        [ "$actual_digest" = "$expected_digest" ] &&
        [ "$actual_ref" = "$expected_ref" ] &&
        [ "$actual_channel" = "$expected_channel" ] &&
        [ "$actual_workflow_id" = "$expected_workflow_id" ] &&
        { [ -z "$expected_workflow_url" ] || [ -z "$actual_workflow_url" ] ||
          [ "$actual_workflow_url" = "$expected_workflow_url" ]; } &&
        [ "$actual_built_at" = "$expected_built_at" ]
}

provenance_sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

ensure_tenant_provenance_schema() {
    local db="${MYSQL_MASTER_DB:-zatca_master}"
    run_mysql "$db" <<'SQL'
ALTER TABLE tenant
    ADD COLUMN IF NOT EXISTS backend_image_ref VARCHAR(512) NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS frontend_image_ref VARCHAR(512) NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS backend_image_digest VARCHAR(255) NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS frontend_image_digest VARCHAR(255) NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS backend_channel VARCHAR(64) NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS frontend_channel VARCHAR(64) NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS backend_version VARCHAR(128) NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS frontend_version VARCHAR(128) NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS backend_commit VARCHAR(128) NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS frontend_commit VARCHAR(128) NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS backend_commit_short VARCHAR(32) NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS frontend_commit_short VARCHAR(32) NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS backend_workflow_run VARCHAR(128) NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS frontend_workflow_run VARCHAR(128) NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS backend_workflow_run_url VARCHAR(512) NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS frontend_workflow_run_url VARCHAR(512) NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS backend_built_at VARCHAR(64) NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS frontend_built_at VARCHAR(64) NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS backend_deployed_at TIMESTAMP NULL DEFAULT NULL,
    ADD COLUMN IF NOT EXISTS frontend_deployed_at TIMESTAMP NULL DEFAULT NULL,
    ADD COLUMN IF NOT EXISTS backend_deployment_status VARCHAR(32) NOT NULL DEFAULT 'unknown',
    ADD COLUMN IF NOT EXISTS frontend_deployment_status VARCHAR(32) NOT NULL DEFAULT 'unknown',
    ADD COLUMN IF NOT EXISTS backend_deployment_error TEXT NULL,
    ADD COLUMN IF NOT EXISTS frontend_deployment_error TEXT NULL;
CREATE TABLE IF NOT EXISTS tenant_deployment_audit (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    tenant_name VARCHAR(100) NOT NULL,
    app_type VARCHAR(16) NOT NULL,
    requested_image_ref VARCHAR(512) NOT NULL DEFAULT '',
    resolved_image_ref VARCHAR(512) NOT NULL DEFAULT '',
    image_digest VARCHAR(255) NOT NULL DEFAULT '',
    channel VARCHAR(64) NOT NULL DEFAULT '',
    semantic_version VARCHAR(128) NOT NULL DEFAULT '',
    commit_sha VARCHAR(128) NOT NULL DEFAULT '',
    commit_short VARCHAR(32) NOT NULL DEFAULT '',
    workflow_run VARCHAR(128) NOT NULL DEFAULT '',
    workflow_run_url VARCHAR(512) NOT NULL DEFAULT '',
    built_at VARCHAR(64) NOT NULL DEFAULT '',
    previous_image_ref VARCHAR(512) NOT NULL DEFAULT '',
    previous_image_digest VARCHAR(255) NOT NULL DEFAULT '',
    backup_id VARCHAR(255) NOT NULL DEFAULT '',
    backup_db_artifact VARCHAR(512) NOT NULL DEFAULT '',
    status VARCHAR(32) NOT NULL,
    error_message TEXT NULL,
    started_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMP NULL DEFAULT NULL,
    INDEX idx_tenant_deployment_audit_tenant (tenant_name, started_at),
    INDEX idx_tenant_deployment_audit_status (status, started_at)
) ENGINE=InnoDB;
ALTER TABLE tenant_deployment_audit
    ADD COLUMN IF NOT EXISTS backup_id VARCHAR(255) NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS backup_db_artifact VARCHAR(512) NOT NULL DEFAULT '';
SQL
}

tenant_record_audit() {
    local tenant="$1" app_type="$2" requested="$3" resolved="$4" digest="$5"
    local channel="$6" version="$7" commit_sha="$8" commit_short="$9"
    local workflow="${10}" workflow_url="${11}" built_at="${12}" previous_ref="${13}"
    local previous_digest="${14}" status="${15}" error_message="${16:-}"
    local backup_id="${17:-}" backup_db_artifact="${18:-}"
    local db="${MYSQL_MASTER_DB:-zatca_master}"
    run_mysql "$db" -e "INSERT INTO tenant_deployment_audit
        (tenant_name, app_type, requested_image_ref, resolved_image_ref,
         image_digest, channel, semantic_version, commit_sha, commit_short,
         workflow_run, workflow_run_url, built_at, previous_image_ref, previous_image_digest,
         backup_id, backup_db_artifact, status, error_message, completed_at)
        VALUES
        ('$(provenance_sql_escape "$tenant")',
         '$(provenance_sql_escape "$app_type")',
         '$(provenance_sql_escape "$requested")',
         '$(provenance_sql_escape "$resolved")',
         '$(provenance_sql_escape "$digest")',
         '$(provenance_sql_escape "$channel")',
         '$(provenance_sql_escape "$version")',
         '$(provenance_sql_escape "$commit_sha")',
         '$(provenance_sql_escape "$commit_short")',
         '$(provenance_sql_escape "$workflow")',
         '$(provenance_sql_escape "$workflow_url")',
         '$(provenance_sql_escape "$built_at")',
         '$(provenance_sql_escape "$previous_ref")',
         '$(provenance_sql_escape "$previous_digest")',
         '$(provenance_sql_escape "$backup_id")',
         '$(provenance_sql_escape "$backup_db_artifact")',
         '$(provenance_sql_escape "$status")',
         '$(provenance_sql_escape "$error_message")',
         NOW());"
}

tenant_record_identity() {
    local tenant="$1" app_type="$2" requested="$3"
    local resolved="$4" digest="$5" channel="$6" version="$7"
    local     commit_sha="$8" commit_short="$9" workflow="${10}" workflow_url="${11}" built_at="${12}"
    local db="${MYSQL_MASTER_DB:-zatca_master}" p
    case "$app_type" in backend|frontend) p="$app_type" ;; *) return 1 ;; esac
    run_mysql "$db" -e "UPDATE tenant SET
        ${p}_image_ref='$(provenance_sql_escape "$requested")',
        ${p}_image_digest='$(provenance_sql_escape "$digest")',
        ${p}_channel='$(provenance_sql_escape "$channel")',
        ${p}_version='$(provenance_sql_escape "$version")',
        ${p}_commit='$(provenance_sql_escape "$commit_sha")',
        ${p}_commit_short='$(provenance_sql_escape "$commit_short")',
        ${p}_workflow_run='$(provenance_sql_escape "$workflow")',
        ${p}_workflow_run_url='$(provenance_sql_escape "$workflow_url")',
        ${p}_built_at='$(provenance_sql_escape "$built_at")',
        ${p}_deployed_at=NOW(),
        ${p}_deployment_status='verified',
        ${p}_deployment_error=''
      WHERE name='$(provenance_sql_escape "$tenant")' LIMIT 1;"
}

tenant_record_failure() {
    local tenant="$1" app_type="$2" message="$3"
    local db="${MYSQL_MASTER_DB:-zatca_master}" p
    case "$app_type" in backend|frontend) p="$app_type" ;; *) return 1 ;; esac
    run_mysql "$db" -e "UPDATE tenant SET
        ${p}_deployment_status='failed',
        ${p}_deployment_error='$(provenance_sql_escape "$message")'
      WHERE name='$(provenance_sql_escape "$tenant")' LIMIT 1;" || return 1
}

tenant_clear_identity() {
    local tenant="$1" app_type="$2" message="${3:-rollback left no known-good identity}"
    local db="${MYSQL_MASTER_DB:-zatca_master}" p
    case "$app_type" in backend|frontend) p="$app_type" ;; *) return 1 ;; esac
    run_mysql "$db" -e "UPDATE tenant SET
        ${p}_image_ref='', ${p}_image_digest='', ${p}_channel='',
        ${p}_version='', ${p}_commit='', ${p}_commit_short='',
        ${p}_workflow_run='', ${p}_workflow_run_url='', ${p}_built_at='', ${p}_deployed_at=NULL,
        ${p}_deployment_status='failed',
        ${p}_deployment_error='$(provenance_sql_escape "$message")'
      WHERE name='$(provenance_sql_escape "$tenant")' LIMIT 1;"
}

tenant_current_identity() {
    local tenant="$1" app_type="$2" db="${MYSQL_MASTER_DB:-zatca_master}" p
    case "$app_type" in backend|frontend) p="$app_type" ;; *) return 1 ;; esac
    run_mysql -N -B "$db" -e "SELECT
        IFNULL(${p}_image_ref,''), IFNULL(${p}_image_digest,''),
        IFNULL(${p}_channel,''), IFNULL(${p}_version,''),
        IFNULL(${p}_commit,''), IFNULL(${p}_commit_short,''),
        IFNULL(${p}_workflow_run,''), IFNULL(${p}_workflow_run_url,''),
        IFNULL(${p}_built_at,'')
      FROM tenant WHERE name='$(provenance_sql_escape "$tenant")' LIMIT 1;" 2>/dev/null |
        head -n1
}
