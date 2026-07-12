#!/usr/bin/env bash
# render-caddy-routes.sh -- render the committed Caddy bundle for this server repo.
#
# Emits two generated-but-committed artifacts under .generated/caddy/:
#
#   apps.caddy    -- all apps/*/*.caddy snippets concatenated (snippet definitions
#                    first, then site blocks with per-site defaults injected).
#                    Mounted read-only into the Caddy container, which must NOT
#                    mount the deploy repo: .env and backup secrets stay outside
#                    the reverse proxy's filesystem.
#   networks.yml  -- compose overlay wiring one private proxy network per enabled
#                    app (from the include list in docker-compose.yml): Caddy
#                    joins every <app>_proxy network, each app joins only its
#                    own. Apps never share a proxy network, so a compromised app
#                    cannot reach another app's backend or forge Remote-* headers.
#
# Both files are derived purely from committed sources, so they are committed
# like lockfiles: run this after adding/changing apps and commit the result.
# CI fails if they drift (scripts/check-generated-sync.sh).
#
# Convention: an app's web-facing service must be named after its directory
# (apps/myapp/ -> service "myapp"); this script fails loudly otherwise.
set -euo pipefail

repo_root="${1:-$(pwd)}"
out_dir="${2:-$repo_root/.generated/caddy}"
routes_file="$out_dir/apps.caddy"
networks_file="$out_dir/networks.yml"
snippets="$(mktemp)"
sites="$(mktemp)"

cleanup() {
  rm -f "$snippets" "$sites"
}
trap cleanup EXIT

mkdir -p "$out_dir"
: > "$snippets"
: > "$sites"

for f in "$routes_file" "$networks_file"; do
  if [[ -d "$f" ]]; then
    echo "ERROR: $f is a directory (docker compose was started before the bundle" >&2
    echo "was rendered, so Docker created the bind-mount source as a directory)." >&2
    echo "Remove it and re-run: rm -rf '$f'" >&2
    exit 1
  fi
done

# --- apps.caddy: concatenate route snippets, definitions before site blocks ---
if [[ -d "$repo_root/apps" ]]; then
  while IFS= read -r snippet; do
    awk -v snip="$snippets" -v site="$sites" '
      {
        line = $0
        trimmed = line
        opens = gsub(/\{/, "{", line)
        closes = gsub(/\}/, "}", line)
        sub(/^[[:space:]]*/, "", trimmed)

        if (depth == 0 && target == "") {
          target = (substr(trimmed, 1, 1) == "(") ? snip : site
        }

        print $0 >> target

        if (depth == 0 && target == site && line ~ /\{[[:space:]]*$/ && substr(trimmed, 1, 1) != "(") {
          print "    encode zstd gzip" >> target
          print "    log {" >> target
          print "        output file /var/log/caddy/access.log {" >> target
          print "            roll_size 20MiB" >> target
          print "            roll_keep 12" >> target
          print "            roll_keep_for 2160h" >> target
          print "        }" >> target
          print "        format json" >> target
          print "    }" >> target
          # Access-log user attribution: forward_auth injects Remote-User on
          # protected routes; recording it gives a per-user access trail that
          # ships to the tamper-evident log bucket. Empty on public routes.
          print "    log_append user {http.request.header.Remote-User}" >> target
          # Security-header baseline for every site. ?-prefix sets a header
          # only when the app did not set its own, so apps can override.
          print "    header {" >> target
          print "        ?Strict-Transport-Security \"max-age=31536000; includeSubDomains\"" >> target
          print "        ?X-Content-Type-Options nosniff" >> target
          print "        ?Referrer-Policy strict-origin-when-cross-origin" >> target
          print "        ?X-Frame-Options DENY" >> target
          print "    }" >> target
          # Static-asset caching. A *fingerprinted* asset URL changes whenever
          # its bytes change, so the browser may cache it forever and never
          # revalidate -- no round-trip, and on a gated app no repeat hit on the
          # forward_auth check (a warm asset never touches the network at all).
          # Two fingerprint conventions are honoured so any app can opt in with
          # whatever its stack already emits:
          #   * content hash in the filename -- app.9f3a1c2b.css
          #     (Vite / webpack / Django ManifestStaticFilesStorage, WhiteNoise)
          #   * a ?v= build tag -- coffee.css?v=9f3a1c2b (hand-rolled busting)
          # Both are scoped to static file extensions, so a *document* URL that
          # happens to carry ?v= is never frozen. "private" (not "public") keeps
          # gated assets out of any shared/CDN cache -- they stay per-browser.
          # ?-prefix defers to an app that sets its own Cache-Control. An app
          # that serves un-fingerprinted assets matches neither rule and keeps
          # its existing ETag revalidation, so this is a no-op until adopted.
          print "    @scaffold_static_hashed path_regexp \\.[0-9a-f]{8,}\\.(?:css|js|mjs|woff2?|ttf|otf|svg|png|jpe?g|webp|avif|gif|ico)$" >> target
          print "    header @scaffold_static_hashed ?Cache-Control \"private, max-age=31536000, immutable\"" >> target
          print "    @scaffold_static_versioned {" >> target
          print "        query v=*" >> target
          print "        path *.css *.js *.mjs *.woff *.woff2 *.ttf *.otf *.svg *.png *.jpg *.jpeg *.webp *.avif *.gif *.ico" >> target
          print "    }" >> target
          print "    header @scaffold_static_versioned ?Cache-Control \"private, max-age=31536000, immutable\"" >> target
        }

        depth += opens - closes
        if (depth == 0) { target = "" }
      }
    ' "$snippet"
    printf '\n' >> "$snippets"
    printf '\n' >> "$sites"
  done < <(find "$repo_root/apps" -mindepth 2 -maxdepth 2 -type f -name '*.caddy' | sort)
fi

{
  printf '# Generated by scaffold/docker/render-caddy-routes.sh; do not edit.\n\n'
  cat "$snippets" "$sites"
} > "$routes_file.tmp"
mv "$routes_file.tmp" "$routes_file"

# --- networks.yml: one private proxy network per enabled app ------------------
# Enabled apps are the uncommented `- apps/<name>/docker-compose.yml` lines in
# the root docker-compose.yml include list — the same single opt-in point that
# controls which apps run.
enabled_apps=()
if [[ -f "$repo_root/docker-compose.yml" ]]; then
  while IFS= read -r app; do
    enabled_apps+=("$app")
  done < <(grep -E '^[[:space:]]*-[[:space:]]+apps/[^/]+/docker-compose\.yml[[:space:]]*$' \
             "$repo_root/docker-compose.yml" \
           | sed -E 's|.*apps/([^/]+)/docker-compose\.yml.*|\1|')
fi

for app in "${enabled_apps[@]+"${enabled_apps[@]}"}"; do
  compose_file="$repo_root/apps/$app/docker-compose.yml"
  if [[ ! -f "$compose_file" ]]; then
    echo "ERROR: docker-compose.yml includes apps/$app/docker-compose.yml but it does not exist" >&2
    exit 1
  fi
  if ! grep -Eq "^  ${app}:[[:space:]]*$" "$compose_file"; then
    echo "ERROR: apps/$app/docker-compose.yml has no service named '$app'." >&2
    echo "The web-facing service must be named after the app directory so the" >&2
    echo "scaffold can attach it to its private proxy network." >&2
    exit 1
  fi
done

{
  printf '# Generated by scaffold/docker/render-caddy-routes.sh; do not edit.\n'
  printf '# Per-app proxy networks: Caddy joins all of them; each app joins only\n'
  printf '# its own, so apps cannot reach each other or forge Remote-* headers.\n'
  if [[ ${#enabled_apps[@]} -eq 0 ]]; then
    printf 'services: {}\n'
  else
    printf 'services:\n'
    printf '  caddy:\n'
    printf '    networks:\n'
    for app in "${enabled_apps[@]}"; do
      printf '      - %s_proxy\n' "$app"
    done
    for app in "${enabled_apps[@]}"; do
      printf '  %s:\n' "$app"
      printf '    networks:\n'
      printf '      - %s_proxy\n' "$app"
    done
    printf 'networks:\n'
    for app in "${enabled_apps[@]}"; do
      printf '  %s_proxy: {}\n' "$app"
    done
  fi
} > "$networks_file.tmp"
mv "$networks_file.tmp" "$networks_file"

echo "Rendered $routes_file"
echo "Rendered $networks_file"
