# =============================================================================
# Dokku Dashboard — multi-stage build
#
# Stage 1 (builder):  compiles the Go binary inside Docker.
#                     No Go installation required on the host or server.
#
# Stage 2 (runtime):  alpine:3.20 + ca-certificates + docker CLI binary.
#                     ~65 MB total vs 278 MB for docker:27-cli.
#
# To rebuild from scratch (CI or manual):
#   docker build --no-cache -t ssdawweq/dokku-dashboard:prod .
#
# On the server, update is just:
#   docker pull ssdawweq/dokku-dashboard:prod
#   docker compose -f docker-compose.prod.yml up -d --force-recreate
#
# BUILD_VERSION and BUILD_COMMIT are embedded in the binary. APP_* arguments
# carry the complete image identity into the running dashboard.
# =============================================================================

# ── Stage 1: compile ─────────────────────────────────────────────────────────
FROM golang:1.25-alpine AS builder

WORKDIR /src

# Download deps first — cached layer, only reruns when go.mod/go.sum change.
COPY go.mod go.sum ./
RUN go mod download

# Build a fully static binary.
COPY . .
ARG BUILD_VERSION=dev
ARG BUILD_COMMIT=unknown
RUN case "$BUILD_VERSION" in ""|*[!A-Za-z0-9._-]*) \
      echo "BUILD_VERSION must contain only letters, digits, '.', '_' or '-'" >&2; exit 1 ;; \
    esac \
 && case "$BUILD_COMMIT" in ""|*[!A-Za-z0-9._-]*) \
      echo "BUILD_COMMIT must contain only letters, digits, '.', '_' or '-'" >&2; exit 1 ;; \
    esac \
 && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -ldflags="-s -w -X github.com/abdul-mohsen/deployment/dashboard/internal/buildinfo.Version=${BUILD_VERSION} -X github.com/abdul-mohsen/deployment/dashboard/internal/buildinfo.Commit=${BUILD_COMMIT}" \
    -trimpath -o /dashboard .

# ── Stage 2: minimal runtime ─────────────────────────────────────────────────
# Use alpine (12 MB) instead of docker:27-cli (278 MB).
# Copy only the docker CLI binary — that is the only host tool the dashboard
# needs (it shells out via "docker exec <dokku-container> dokku ...").
FROM docker:27-cli AS docker-bin

FROM debian:bookworm-slim AS tzdata

FROM alpine:3.20

ARG BUILD_VERSION=dev
ARG BUILD_COMMIT=unknown
ARG APP_VERSION=dev
ARG APP_IMAGE_VERSION=dev
ARG APP_IMAGE_TAG=dev
ARG APP_IMAGE_CHANNEL=dev
ARG APP_IMAGE_REF=
ARG APP_IMAGE_DIGEST=
ARG APP_IMAGE_COMMIT=unknown
ARG APP_IMAGE_COMMIT_SHORT=
ARG APP_WORKFLOW_RUN_ID=
ARG APP_WORKFLOW_RUN_URL=
ARG APP_SOURCE=
ARG APP_BUILT_AT=

# Copy ca-certificates from the builder (avoids apk network calls on restricted networks).
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
# Go's Alpine image does not ship zoneinfo; copy it from a data-only stage.
COPY --from=tzdata /usr/share/zoneinfo /usr/share/zoneinfo

# Docker CLI binary from the official image.
COPY --from=docker-bin /usr/local/bin/docker /usr/local/bin/docker

# Dashboard binary.
COPY --from=builder /dashboard /app/dashboard

LABEL org.opencontainers.image.version=$BUILD_VERSION \
      org.opencontainers.image.revision=$BUILD_COMMIT \
      org.opencontainers.image.source=$APP_SOURCE \
      org.opencontainers.image.created=$APP_BUILT_AT \
      com.ifritah.build.channel=$APP_IMAGE_CHANNEL \
      com.ifritah.build.tag=$APP_IMAGE_TAG \
      com.ifritah.build.image_ref=$APP_IMAGE_REF \
      com.ifritah.build.digest=$APP_IMAGE_DIGEST \
      com.ifritah.build.commit=$APP_IMAGE_COMMIT \
      com.ifritah.build.commit_short=$APP_IMAGE_COMMIT_SHORT \
      com.ifritah.build.workflow_run_id=$APP_WORKFLOW_RUN_ID \
      com.ifritah.build.workflow_run_url=$APP_WORKFLOW_RUN_URL

ENV APP_VERSION="${APP_VERSION}" \
    APP_IMAGE_VERSION="${APP_IMAGE_VERSION}" \
    APP_IMAGE_TAG="${APP_IMAGE_TAG}" \
    APP_IMAGE_CHANNEL="${APP_IMAGE_CHANNEL}" \
    APP_IMAGE_REF="${APP_IMAGE_REF}" \
    APP_IMAGE_DIGEST="${APP_IMAGE_DIGEST}" \
    APP_IMAGE_COMMIT="${APP_IMAGE_COMMIT}" \
    APP_IMAGE_COMMIT_SHORT="${APP_IMAGE_COMMIT_SHORT}" \
    APP_WORKFLOW_RUN_ID="${APP_WORKFLOW_RUN_ID}" \
    APP_WORKFLOW_RUN_URL="${APP_WORKFLOW_RUN_URL}" \
    APP_SOURCE="${APP_SOURCE}" \
    APP_BUILT_AT="${APP_BUILT_AT}"

WORKDIR /app
EXPOSE 8080
ENTRYPOINT ["/app/dashboard"]
