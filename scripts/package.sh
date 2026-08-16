#!/usr/bin/env bash
# Builds the release artifacts: the Godot addon zip and cross-compiled relay binaries.
#
#   scripts/package.sh v0.2.0        # explicit version
#   scripts/package.sh               # derives it from the current git tag
#
# Output lands in dist/.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

VERSION="${1:-$(git describe --tags --exact-match 2>/dev/null || git describe --tags 2>/dev/null || echo "v0.0.0-dev")}"
# plugin.cfg wants a bare version, the tag carries a leading v.
BARE_VERSION="${VERSION#v}"

DIST="${REPO_ROOT}/dist"
rm -rf "${DIST}"
mkdir -p "${DIST}"

echo "==> packaging ${VERSION}"

# --- Addon -------------------------------------------------------------------
# Staged in a temp tree so plugin.cfg can carry the release version without the
# working copy being modified.
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

mkdir -p "${STAGE}/addons"
cp -RL addons/melay "${STAGE}/addons/melay"
sed -i.bak "s/^version=\".*\"/version=\"${BARE_VERSION}\"/" "${STAGE}/addons/melay/plugin.cfg"
rm -f "${STAGE}/addons/melay/plugin.cfg.bak"

ADDON_ZIP="${DIST}/melay-addon-${VERSION}.zip"
(cd "${STAGE}" && zip -qr "${ADDON_ZIP}" addons)
echo "    addon  $(basename "${ADDON_ZIP}")"

# --- Server ------------------------------------------------------------------
# CGO stays off so the pure-Go sqlite driver cross-compiles cleanly everywhere.
build_server() {
	local goos="$1" goarch="$2" ext="${3:-}"
	local name="melay-${VERSION}-${goos}-${goarch}"
	local out="${STAGE}/${name}"

	mkdir -p "${out}"
	(cd server && CGO_ENABLED=0 GOOS="${goos}" GOARCH="${goarch}" \
		go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" \
		-o "${out}/melay${ext}" ./cmd/melay)
	cp README.md LICENSE "${out}/"
	cp server/melay.yaml "${out}/melay.yaml.example"

	if [[ "${goos}" == "windows" ]]; then
		(cd "${STAGE}" && zip -qr "${DIST}/${name}.zip" "${name}")
		echo "    server $(basename "${DIST}/${name}.zip")"
	else
		tar -czf "${DIST}/${name}.tar.gz" -C "${STAGE}" "${name}"
		echo "    server $(basename "${DIST}/${name}.tar.gz")"
	fi
}

build_server linux   amd64
build_server linux   arm64
build_server darwin  amd64
build_server darwin  arm64
build_server windows amd64 .exe

# --- Checksums ---------------------------------------------------------------
(cd "${DIST}" && sha256sum ./* > SHA256SUMS)

echo "==> done"
ls -la "${DIST}"
