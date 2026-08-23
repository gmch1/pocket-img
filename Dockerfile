# syntax=docker/dockerfile:1.7

ARG NODE_IMAGE=node:24-alpine
ARG GO_IMAGE=golang:1.26.5-alpine
ARG RUNTIME_IMAGE=alpine:3.22
ARG VERSION=dev

FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS frontend-build
WORKDIR /workspace/frontend

COPY frontend/package.json frontend/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci

COPY frontend/ ./
RUN npm run build

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS backend-build
ARG TARGETOS
ARG TARGETARCH
ARG GOPROXY=https://proxy.golang.org,direct
ARG VERSION

WORKDIR /workspace

COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod GOPROXY=${GOPROXY} go mod download

COPY cmd/ ./cmd/
COPY internal/ ./internal/
COPY --from=frontend-build /workspace/internal/webui/dist/ ./internal/webui/dist/

RUN mkdir -p /runtime-data
RUN chown 10001:10001 /runtime-data
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} GOPROXY=${GOPROXY} \
    go build \
      -buildvcs=false \
      -tags=nodynamic \
      -trimpath \
      -ldflags="-s -w -X main.version=${VERSION}" \
      -o /pocketimg \
      ./cmd/server

FROM ${RUNTIME_IMAGE} AS runtime
ARG VERSION

LABEL org.opencontainers.image.title="PocketIMG" \
      org.opencontainers.image.description="Self-hosted PocketIMG web and API server" \
      org.opencontainers.image.source="https://github.com/gmch1/pocket-img" \
      org.opencontainers.image.version="${VERSION}"

COPY --from=backend-build /pocketimg /usr/local/bin/pocketimg
COPY --from=backend-build --chown=10001:10001 /runtime-data/ /data/

ENV PIH_ADDR=0.0.0.0:8080 \
    PIH_DATA_DIR=/data

VOLUME ["/data"]
EXPOSE 8080
STOPSIGNAL SIGTERM

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/healthz"]

USER 10001:10001
ENTRYPOINT ["/usr/local/bin/pocketimg"]
