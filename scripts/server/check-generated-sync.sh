#!/usr/bin/env bash
# Fail if the committed Caddy bundle (.generated/caddy/) is out of sync with
# its sources (apps/*/*.caddy and the docker-compose.yml include list).
# The bundle is generated-but-committed, like a lockfile: after changing apps,
# run `bash scaffold/docker/render-caddy-routes.sh` and commit the result.
set -euo pipefail

# The server repo root: this file is installed at <server>/scaffold/scripts/server/,
# so three levels up, unless the calling shim says otherwise.
ROOT_DIR="${SERVER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cd "$ROOT_DIR"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

bash scaffold/docker/render-caddy-routes.sh "$ROOT_DIR" "$tmp_dir"

if ! diff -ru .generated/caddy "$tmp_dir"; then
  echo "" >&2
  echo "ERROR: .generated/caddy is out of sync with apps/ and docker-compose.yml." >&2
  echo "Re-render and commit it:" >&2
  echo "  bash scaffold/docker/render-caddy-routes.sh" >&2
  echo "  git add .generated" >&2
  exit 1
fi

echo "OK: .generated/caddy matches its sources"
