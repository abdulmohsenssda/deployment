# =============================================================================
# Backend Dockerfile — multi-stage Go build with Atlas migrations baked in
# =============================================================================
# Build:  docker build --build-arg APP_VERSION=v0.0.1 --build-arg APP_COMMIT=local -t youruser/ifritah-api:v0.0.1 .
# Run:    docker run --env-file .env -p 3000:3000 youruser/ifritah-api:v0.0.1
# =============================================================================

# ---- Build stage ----
FROM golang:1.23-alpine AS builder

RUN apk add --no-cache git ca-certificates tzdata curl

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /app/server ./cmd/server

# Install Atlas CLI (pinned for reproducibility)
ARG ATLAS_VERSION=v0.28.0
RUN curl -sSf https://atlasgo.sh | sh -s -- --community --yes \
    && cp /root/.atlas/bin/atlas /app/atlas

# ---- Runtime stage ----
FROM alpine:3.20

ARG APP_VERSION=v0.0.1
ARG APP_COMMIT=unknown
ENV APP_VERSION=$APP_VERSION
ENV APP_COMMIT=$APP_COMMIT
ARG APP_IMAGE_VERSION=$APP_VERSION
ARG APP_IMAGE_COMMIT=unknown
ARG APP_IMAGE_CHANNEL=dev
ARG APP_IMAGE_REF=
ARG APP_IMAGE_DIGEST=
ARG APP_SOURCE=
ARG APP_WORKFLOW_RUN_ID=
ARG APP_WORKFLOW_RUN_URL=
ARG APP_BUILT_AT=
ENV APP_VERSION=$APP_VERSION
ENV APP_IMAGE_VERSION=$APP_IMAGE_VERSION \
    APP_IMAGE_COMMIT=$APP_IMAGE_COMMIT \
    APP_IMAGE_CHANNEL=$APP_IMAGE_CHANNEL \
    APP_IMAGE_REF=$APP_IMAGE_REF \
    APP_SOURCE=$APP_SOURCE \
    APP_WORKFLOW_RUN_ID=$APP_WORKFLOW_RUN_ID \
    APP_WORKFLOW_RUN_URL=$APP_WORKFLOW_RUN_URL \
    APP_BUILT_AT=$APP_BUILT_AT
LABEL org.opencontainers.image.version=$APP_VERSION
LABEL org.opencontainers.image.revision=$APP_IMAGE_COMMIT \
org.opencontainers.image.source=$APP_SOURCE \
      org.opencontainers.image.created=$APP_BUILT_AT \
      org.opencontainers.image.channel=$APP_IMAGE_CHANNEL \
      com.ifritah.build.version=$APP_IMAGE_VERSION \
      com.ifritah.build.commit=$APP_IMAGE_COMMIT \
      com.ifritah.build.channel=$APP_IMAGE_CHANNEL \
      com.ifritah.build.image_ref=$APP_IMAGE_REF \
      com.ifritah.build.digest=$APP_IMAGE_DIGEST \
      com.ifritah.build.workflow_run_id=$APP_WORKFLOW_RUN_ID \
      com.ifritah.build.workflow_run_url=$APP_WORKFLOW_RUN_URL

RUN apk add --no-cache ca-certificates tzdata \
    && addgroup -S app && adduser -S app -G app

WORKDIR /app

COPY --from=builder /app/server .
COPY --from=builder /app/atlas /usr/local/bin/atlas
COPY --from=builder /src/migrations /app/migrations

RUN mkdir -p /app/uploads /app/data && chown -R app:app /app

USER app
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget --spider -q http://localhost:3000/healthz || exit 1

ENTRYPOINT ["./server"]
