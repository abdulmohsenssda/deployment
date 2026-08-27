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
LABEL org.opencontainers.image.version=$APP_VERSION \
      org.opencontainers.image.revision=$APP_COMMIT

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
    CMD wget --spider -q http://localhost:3000/api/health || exit 1

ENTRYPOINT ["./server"]
