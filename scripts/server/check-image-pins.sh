#!/usr/bin/env bash
# check-image-pins.sh — fail when any compose image is not pinned by digest.
#
# Supply-chain gate (Essential Eight patch/application control on Linux =
# image allowlisting + pinning): every `image:` in the compose files this
# stack loads must carry @sha256:… so a deploy pulls exactly the bytes that
# were reviewed. Renovate's pinDigests keeps pins current.
#
# What is checked:
#   * the root docker-compose.yml include list — the authoritative set of what
#     compose actually loads. Every entry must be one of
#     apps/<name>/docker-compose.yml, scaffold/docker/caddy.base.yml or
#     .generated/caddy/networks.yml; anything else fails, so a compose file
#     cannot be slipped in under a path the other checks never look at;
#   * every apps/*/docker-compose.yml, included or not;
#   * no `build:` (a locally built image has no digest to pin);
#   * deploy hooks: no docker run/pull/create of an unpinned image and no
#     download piped into a shell.
# Trailing comments on an image: line are stripped before the digest test, so
# a comment cannot hide an unpinned image.
set -euo pipefail

# The server repo root: this file is installed at <server>/scaffold/scripts/server/,
# so three levels up, unless the calling shim says otherwise.
ROOT_DIR="${SERVER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cd "$ROOT_DIR"

fail=0
compose_files=()
add_file() {
  local existing
  for existing in "${compose_files[@]+"${compose_files[@]}"}"; do
    [[ "$existing" == "$1" ]] && return 0
  done
  compose_files+=("$1")
}

# 1. The root include list.
if [[ -f docker-compose.yml ]]; then
  while IFS= read -r inc; do
    case "$inc" in
      scaffold/docker/caddy.base.yml)
        # The scaffold submodule may not be checked out in every CI job.
        if [[ -f "$inc" ]]; then add_file "$inc"; else echo "NOTE: scaffold submodule not checked out — skipping caddy.base.yml"; fi ;;
      .generated/caddy/networks.yml)
        ;;  # generated network wiring, declares no images
      apps/*/docker-compose.yml)
        if [[ -f "$inc" ]]; then add_file "$inc"; else echo "ERROR: docker-compose.yml includes $inc but it does not exist" >&2; fail=1; fi ;;
      *)
        echo "ERROR: docker-compose.yml includes '$inc', which is outside the checked set" >&2
        echo "       (apps/<name>/docker-compose.yml, scaffold/docker/caddy.base.yml, .generated/caddy/networks.yml)" >&2
        fail=1 ;;
    esac
  done < <(awk '
      /^include:[[:space:]]*$/ { in_inc = 1; next }
      in_inc && /^[^[:space:]#]/ { in_inc = 0 }
      in_inc && /^[[:space:]]*-[[:space:]]+/ {
        sub(/^[[:space:]]*-[[:space:]]+/, ""); sub(/[[:space:]]+#.*$/, ""); print
      }
    ' docker-compose.yml)
fi

# 2. Every app compose file, whether or not it is currently included.
for f in apps/*/docker-compose.yml; do
  [[ -f "$f" ]] && add_file "$f"
done

[[ ${#compose_files[@]} -gt 0 ]] || { echo "ERROR: no compose files found" >&2; exit 1; }

for f in "${compose_files[@]}"; do
  while IFS= read -r line; do
    echo "ERROR: unpinned image in $f: ${line#"${line%%[![:space:]]*}"}" >&2
    fail=1
  done < <(grep -E '^[[:space:]]*image:' "$f" | sed -E 's/[[:space:]]+#.*$//' | grep -v '@sha256:' || true)
  if grep -qE '^[[:space:]]*build:' "$f"; then
    echo "ERROR: $f declares build: — images must come from a registry, pinned by digest" >&2
    fail=1
  fi
done

for f in apps/*/deploy.sh; do
  [[ -f "$f" ]] || continue
  while IFS= read -r line; do
    echo "ERROR: unpinned helper image in $f: ${line#"${line%%[![:space:]]*}"}" >&2
    fail=1
  done < <(grep -nE '\bdocker[[:space:]]+(container[[:space:]]+)?(run|pull|create)\b' "$f" | grep -v '@sha256:' || true)
  while IFS= read -r line; do
    echo "ERROR: download piped into a shell in $f: ${line#"${line%%[![:space:]]*}"}" >&2
    fail=1
  done < <(grep -nE '\b(curl|wget)\b[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|da)?sh\b' "$f" || true)
done

if [[ $fail -ne 0 ]]; then
  echo "" >&2
  echo "Pin images as repo:tag@sha256:<digest> (docker buildx imagetools inspect <image>" >&2
  echo "prints the digest; Renovate pinDigests maintains compose pins afterwards)." >&2
  echo "Avoid ad-hoc helper containers in deploy hooks; prefer declared compose services." >&2
  exit 1
fi

echo "Image pin checks passed (${#compose_files[@]} compose file(s))."
