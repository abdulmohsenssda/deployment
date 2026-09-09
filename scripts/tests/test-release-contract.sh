#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

contains() {
    local file="$1" text="$2" description="$3"
    grep -Fq "$text" "$file" || fail "$description"
    pass "$description"
}

not_contains_any() {
    local description="$1"
    shift
    local path
    for path in "$@"; do
        if [ -d "$path" ]; then
            grep -R -Fq '/api/health' "$path" && fail "$description"
        elif grep -Fq '/api/health' "$path"; then
            fail "$description"
        fi
    done
    pass "$description"
}

echo "=== /healthz contract ==="
contains dashboard/internal/web/web.go 'r.Get("/healthz"' \
    "dashboard exposes /healthz"
contains dashboard/internal/web/web.go 'Write([]byte("ok"))' \
    "dashboard /healthz returns ok"
contains scripts/create-tenant.sh "echo '/healthz' >" \
    "tenant checks use /healthz"
contains scripts/deploy-all.sh 'HEALTH_URL}/healthz' \
    "deploy health probes use /healthz"
contains scripts/status.sh 'path="/healthz"' \
    "status health probes use /healthz"
contains templates/backend/Dockerfile 'http://localhost:3000/healthz' \
    "backend container healthcheck uses /healthz"
not_contains_any "legacy /api/health probes are absent" \
    scripts/*.sh templates dashboard REQUIREMENTS.md

echo
echo "=== BuildIdentity environment and label schema ==="
for file in templates/backend/Dockerfile templates/frontend/Dockerfile; do
    for key in \
        APP_VERSION APP_IMAGE_VERSION APP_IMAGE_COMMIT APP_IMAGE_CHANNEL \
        APP_IMAGE_REF APP_WORKFLOW_RUN_ID APP_WORKFLOW_RUN_URL APP_BUILT_AT; do
        contains "$file" "$key" "$file declares $key"
    done
    for label in \
        org.opencontainers.image.version \
        org.opencontainers.image.revision \
        org.opencontainers.image.source \
        org.opencontainers.image.created \
        com.ifritah.build.channel \
        com.ifritah.build.image_ref \
        com.ifritah.build.workflow_run_id \
        com.ifritah.build.workflow_run_url; do
        contains "$file" "$label" "$file declares $label"
    done
done

for file in templates/backend/.github/workflows/deploy.yml \
            templates/frontend/.github/workflows/deploy.yml; do
    for key in \
        APP_VERSION APP_IMAGE_VERSION APP_IMAGE_COMMIT APP_IMAGE_CHANNEL \
        APP_IMAGE_REF APP_WORKFLOW_RUN_ID APP_WORKFLOW_RUN_URL APP_BUILT_AT; do
        contains "$file" "$key" "$file passes $key"
    done
    for label in \
        org.opencontainers.image.version \
        org.opencontainers.image.revision \
        org.opencontainers.image.source \
        org.opencontainers.image.created \
        com.ifritah.build.channel \
        com.ifritah.build.image_ref \
        com.ifritah.build.workflow_run_id \
        com.ifritah.build.workflow_run_url; do
        contains "$file" "$label" "$file publishes $label"
    done
done

echo
echo "=== Dashboard image identity and publication ==="
for key in \
    APP_VERSION APP_IMAGE_VERSION APP_IMAGE_TAG APP_IMAGE_CHANNEL \
    APP_IMAGE_REF APP_IMAGE_COMMIT APP_IMAGE_COMMIT_SHORT \
    APP_WORKFLOW_RUN_ID APP_WORKFLOW_RUN_URL APP_SOURCE APP_BUILT_AT; do
    contains dashboard/Dockerfile "$key" "dashboard Dockerfile declares $key"
done
for label in \
    org.opencontainers.image.version \
    org.opencontainers.image.revision \
    org.opencontainers.image.source \
    org.opencontainers.image.created \
    com.ifritah.build.channel \
    com.ifritah.build.tag \
    com.ifritah.build.image_ref \
    com.ifritah.build.commit \
    com.ifritah.build.workflow_run_id \
    com.ifritah.build.workflow_run_url; do
    contains dashboard/Dockerfile "$label" "dashboard Dockerfile declares $label"
    contains .github/workflows/dashboard-image.yml "$label" "dashboard workflow publishes $label"
done
contains .github/workflows/dashboard-image.yml 'branches: [main]' \
    "dashboard workflow targets main"
contains .github/workflows/dashboard-image.yml 'DOCKERHUB_USERNAME is missing or invalid' \
    "dashboard workflow validates Docker Hub owner"
contains .github/workflows/dashboard-image.yml 'docker buildx imagetools inspect' \
    "dashboard workflow verifies published manifests"
contains .github/workflows/dashboard-image.yml 'id: publish' \
    "dashboard workflow exposes the published image digest"
contains .github/workflows/dashboard-image.yml 'PUBLISHED_DIGEST: ${{ steps.publish.outputs.digest }}' \
    "dashboard workflow verifies the build action digest without truncating inspect output"
contains dashboard/prod-up.sh 'DASHBOARD_IMAGE_DIGEST' \
    "dashboard startup resolves the pulled image digest"
contains dashboard/docker-compose.prod.yml 'APP_IMAGE_DIGEST' \
    "dashboard compose passes the resolved image digest"

contains scripts/tenant-provenance.sh 'BUILD_WORKFLOW_RUN_ID' \
    "tenant provenance reads workflow run identity"
contains scripts/tenant-provenance.sh 'BUILD_IMAGE_REF' \
    "tenant provenance reads image reference identity"
contains scripts/tenant-provenance.sh 'BUILD_DIGEST' \
    "tenant provenance verifies image digest identity"

echo
echo "All release contract checks passed."
