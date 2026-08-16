#!/usr/bin/env bash
# Previews the documentation site locally. GitHub Pages builds docs/ with Jekyll, and
# there is no Ruby on this machine, so this runs it in a container.
#
#   scripts/serve-docs.sh            # http://localhost:4000
#   scripts/serve-docs.sh 4001       # a different port
#
# Gems are cached in a named volume, so only the first run is slow.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${1:-4000}"

echo "==> building the site, first run installs gems and takes a few minutes"
echo "==> once it says 'Server running', open http://localhost:${PORT}"

# baseurl is emptied so links resolve at the root locally. In production the site
# lives under /melay, which is what docs/_config.yml sets.
docker run --rm -it \
	-v "${REPO_ROOT}/docs:/site" \
	-v melay-docs-gems:/usr/local/bundle \
	-w /site \
	-p "${PORT}:4000" \
	ruby:3.3 \
	bash -c "bundle install --quiet && bundle exec jekyll serve --host 0.0.0.0 --baseurl '' --force_polling"
