#!/usr/bin/env bash
# check-digest-freshness.sh — compare every pinned image digest against the
# registry's CURRENT digest for that tag. Exit 1 (with a drift report) when a
# pin is stale.
#
# This is the truth behind "digests are kept current": with the Renovate app
# enabled the drift arrives as a bump PR; without it, the weekly
# digest-freshness workflow turns drift into a GitHub issue. Either way, a
# stale pin cannot be silent.
#
# Anonymous registry API only — no credentials needed for public images.
set -euo pipefail

# The server repo root: this file is installed at <server>/scaffold/scripts/server/,
# so three levels up, unless the calling shim says otherwise.
ROOT_DIR="${SERVER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cd "$ROOT_DIR"

ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'

current_digest() {
  # current_digest <repo-with-registry> <tag> — prints sha256:… or "ERROR"
  local ref="$1" tag="$2" registry repo token url
  case "$ref" in
    ghcr.io/*)
      registry="ghcr.io"; repo="${ref#ghcr.io/}"
      token="$(curl -fsS "https://ghcr.io/token?scope=repository:${repo}:pull" \
        | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')" || { echo ERROR; return; }
      url="https://ghcr.io/v2/${repo}/manifests/${tag}"
      ;;
    *.*/*)  # any other explicit registry — best effort, unauthenticated
      registry="${ref%%/*}"; repo="${ref#*/}"
      token=""; url="https://${registry}/v2/${repo}/manifests/${tag}"
      ;;
    *)      # docker hub (implicit registry; add library/ for official images)
      repo="$ref"; [[ "$repo" == */* ]] || repo="library/${repo}"
      token="$(curl -fsS "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" \
        | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')" || { echo ERROR; return; }
      url="https://registry-1.docker.io/v2/${repo}/manifests/${tag}"
      ;;
  esac
  curl -fsSI ${token:+-H "Authorization: Bearer ${token}"} -H "Accept: ${ACCEPT}" "$url" 2>/dev/null \
    | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:" {print $2}' | head -n1 || echo ERROR
}

compose_files=(apps/*/docker-compose.yml)
[[ -f scaffold/docker/caddy.base.yml ]] && compose_files+=(scaffold/docker/caddy.base.yml)

drift=0
checked=0
while IFS= read -r line; do
  image="$(printf '%s' "$line" | sed -E 's/.*image:[[:space:]]*//; s/[[:space:]]*(#.*)?$//')"
  [[ "$image" == *@sha256:* ]] || continue
  pinned="${image#*@}"
  ref_tag="${image%@*}"
  ref="${ref_tag%:*}"
  tag="${ref_tag##*:}"
  live="$(current_digest "$ref" "$tag")"
  checked=$((checked + 1))
  if [[ "$live" == "ERROR" || -z "$live" ]]; then
    echo "WARN  ${ref}:${tag} — could not resolve current digest (registry unreachable?)"
  elif [[ "$live" != "$pinned" ]]; then
    echo "DRIFT ${ref}:${tag}"
    echo "      pinned:  ${pinned}"
    echo "      current: ${live}"
    drift=1
  else
    echo "OK    ${ref}:${tag}"
  fi
done < <(grep -rhE '^\s*image:' "${compose_files[@]}" | grep -v '^\s*#')

echo "---"
echo "checked ${checked} pinned image(s)"
if [[ $drift -ne 0 ]]; then
  echo "Digest drift detected: update the pin(s) above (test, then commit), or"
  echo "enable the Renovate app to receive these as automated PRs."
  exit 1
fi
echo "All pins current."
