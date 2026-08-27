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
# =============================================================================

# ── Stage 1: compile ─────────────────────────────────────────────────────────
FROM golang:1.25-alpine AS builder

WORKDIR /src

# Download deps first — cached layer, only reruns when go.mod/go.sum change.
COPY go.mod go.sum ./
RUN go mod download

# Build a fully static binary.
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -ldflags="-s -w" -trimpath -o /dashboard .

# ── Stage 2: minimal runtime ─────────────────────────────────────────────────
# Use alpine (12 MB) instead of docker:27-cli (278 MB).
# Copy only the docker CLI binary — that is the only host tool the dashboard
# needs (it shells out via "docker exec <dokku-container> dokku ...").
FROM docker:27-cli AS docker-bin

FROM debian:bookworm-slim AS tzdata

FROM alpine:3.20

# Copy ca-certificates from the builder (avoids apk network calls on restricted networks).
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
# Go's Alpine image does not ship zoneinfo; copy it from a data-only stage.
COPY --from=tzdata /usr/share/zoneinfo /usr/share/zoneinfo

# Docker CLI binary from the official image.
COPY --from=docker-bin /usr/local/bin/docker /usr/local/bin/docker

# Dashboard binary.
COPY --from=builder /dashboard /app/dashboard

WORKDIR /app
EXPOSE 8080
ENTRYPOINT ["/app/dashboard"]
