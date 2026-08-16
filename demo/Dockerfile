# Builds a relay that also serves this demo's web export at /play, so the game and the
# WebSocket share an origin. That removes mixed content and CORS from the picture, and
# lets the server send the cross-origin isolation headers a threaded export needs.
#
# Export the game first:
#   godot --headless --export-release "Web" build/web/index.html
#
# Then from the repo root:
#   docker build -f demo/Dockerfile -t melay-demo .

FROM golang:1.26-alpine AS build
WORKDIR /src

COPY server/go.mod server/go.sum ./
RUN go mod download

COPY server/ ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/melay ./cmd/melay

FROM alpine:3.21 AS layout
RUN mkdir -p /data && chown 65532:65532 /data

# Godot's wasm is around 38MB raw. Pre-compressing keeps the download sane and stays
# under the 32MB ceiling Cloud Run puts on a response it cannot stream. The originals
# are kept for clients that do not accept gzip.
FROM alpine:3.21 AS web
COPY demo/build/web /srv/web
RUN find /srv/web -type f \
		\( -name '*.wasm' -o -name '*.js' -o -name '*.pck' -o -name '*.html' \
		   -o -name '*.json' -o -name '*.css' -o -name '*.svg' \) \
		-exec sh -c 'gzip -9 -c "$1" > "$1.gz"' _ {} \;

FROM scratch
COPY --from=build /out/melay /melay
COPY --from=layout --chown=65532:65532 /data /data
COPY --from=web /srv/web /srv/web

USER 65532:65532
WORKDIR /data
EXPOSE 8890

ENV MELAY_WEB_DIR="/srv/web" \
	MELAY_DATABASE_URL="file:/data/melay.db" \
	MELAY_LOG_JSON="true" \
	TMPDIR="/data"

ENTRYPOINT ["/melay"]
CMD ["--config", "/data/melay.yaml"]
