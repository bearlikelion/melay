#!/usr/bin/env bash
# Deploys the relay to Google Cloud Run, optionally bundling the demo's web export so
# the game is served from the same origin as the WebSocket.
#
#   scripts/deploy-cloudrun.sh            # relay only
#   scripts/deploy-cloudrun.sh --with-web # relay plus demo/build/web at /play
#
# Override any of these with environment variables.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

PROJECT="${MELAY_GCP_PROJECT:-your-gcp-project}"
REGION="${MELAY_GCP_REGION:-us-east1}"
SERVICE="${MELAY_GCP_SERVICE:-melay}"
REPOSITORY="${MELAY_GCP_REPO:-melay}"
TAG="${MELAY_TAG:-$(date +%Y%m%d-%H%M%S)}"

WITH_WEB=0
[[ "${1:-}" == "--with-web" ]] && WITH_WEB=1

IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${REPOSITORY}/${SERVICE}:${TAG}"

if [[ "${WITH_WEB}" == "1" ]]; then
	if [[ ! -f demo/build/web/index.html ]]; then
		echo "demo/build/web/index.html is missing. Export the game first:" >&2
		echo '  cd demo && godot --headless --export-release "Web" build/web/index.html' >&2
		exit 1
	fi
	DOCKERFILE=demo/Dockerfile
	CONTEXT=.
	echo "==> building relay + web export"
else
	DOCKERFILE=server/Dockerfile
	CONTEXT=server
	echo "==> building relay"
fi

# linux/amd64 explicitly, because Cloud Run will not run an arm64 image built on an
# Apple Silicon machine.
docker build --platform linux/amd64 -f "${DOCKERFILE}" -t "${IMAGE}" "${CONTEXT}"
docker push "${IMAGE}"

echo "==> deploying ${SERVICE} to ${REGION}"
# max-instances is 1 on purpose: rooms live in memory on whichever instance created
# them, so a second instance would hide rooms from half the players.
gcloud run deploy "${SERVICE}" \
	--image "${IMAGE}" \
	--project "${PROJECT}" \
	--region "${REGION}" \
	--allow-unauthenticated \
	--min-instances 0 \
	--max-instances 1 \
	--session-affinity \
	--timeout 3600 \
	--memory 512Mi \
	--cpu 1 \
	--set-env-vars 'MELAY_DATABASE_URL=file:/tmp/melay.db,TMPDIR=/tmp,MELAY_LOG_JSON=true' \
	--quiet

URL="$(gcloud run services describe "${SERVICE}" --project "${PROJECT}" \
	--region "${REGION}" --format='value(status.url)')"

echo
echo "relay      ${URL/https:/wss:}"
echo "dashboard  ${URL}"
if [[ "${WITH_WEB}" == "1" ]]; then
	echo "game       ${URL}/play/"
fi
