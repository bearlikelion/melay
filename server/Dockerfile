# syntax=docker/dockerfile:1

FROM golang:1.26-alpine AS build
WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .
ARG VERSION=dev
# CGO stays off so the pure-Go sqlite driver yields a fully static binary.
# No BuildKit cache mounts here, so this builds anywhere including Cloud Build.
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /out/melay ./cmd/melay

# Staged so the scratch image gets a writable data directory owned by the runtime user.
FROM alpine:3.21 AS layout
RUN mkdir -p /data && chown 65532:65532 /data

FROM scratch
COPY --from=build /out/melay /melay
COPY --from=layout --chown=65532:65532 /data /data

USER 65532:65532
WORKDIR /data
EXPOSE 8890

# MELAY_ADDR is deliberately unset so a platform-supplied PORT can win. The config
# default is :8890, which is what a plain `docker run -p 8890:8890` gets.
ENV MELAY_DATABASE_URL="file:/data/melay.db" \
	MELAY_LOG_JSON="true" \
	TMPDIR="/data"

ENTRYPOINT ["/melay"]
CMD ["--config", "/data/melay.yaml"]
