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

        # A brace inside a comment is still counted below and would fold one
        # block into the next: fail the render instead of mis-wiring a route.
        if (substr(trimmed, 1, 1) == "#" && line ~ /[{}]/) {
          printf "ERROR: %s:%d: brace inside a comment (the renderer counts braces)\n", FILENAME, FNR > "/dev/stderr"
          bad = 1
        }

        if (depth == 0 && target == "") {
          target = (substr(trimmed, 1, 1) == "(") ? snip : site
        }

        # Every app upstream in a site block must drop the gateway session
        # cookie (import strip_auth_cookie; on a public route import
        # strip_public, which also drops client-sent Remote-* headers; or an
        # equivalent header_up Cookie rewrite): the cookie is scoped to the
        # whole domain and is a live
        # estate-wide bearer credential no app needs. The guards do this
        # already; this catches hand-written reverse_proxy lines. The auth
        # service itself (auth:8080) is the one upstream that must see it. A
        # deliberate exception is declared on the preceding line with
        #   # scaffold-lint: allow-session-cookie
        if (target == site && depth > 0 && trimmed ~ /^reverse_proxy([[:space:]]|$)/ && trimmed !~ /auth:8080/) {
          if (prev_trimmed ~ /scaffold-lint: allow-session-cookie/) {
            # explicit opt-out
          } else if (line ~ /\{[[:space:]]*$/) {
            in_proxy = 1; proxy_depth = depth; proxy_line = FNR; seen_strip = 0
          } else {
            printf "ERROR: %s:%d: reverse_proxy without a block; use a block with import strip_auth_cookie so the gateway session cookie never reaches the app\n", FILENAME, FNR > "/dev/stderr"
            bad = 1
          }
        } else if (in_proxy && (trimmed ~ /^import strip_auth_cookie/ || trimmed ~ /^import strip_public/ || trimmed ~ /^header_up Cookie/)) {
          seen_strip = 1
        }

        print $0 >> target

        if (depth == 0 && target == site && line ~ /\{[[:space:]]*$/ && substr(trimmed, 1, 1) != "(") {
          print "    encode zstd gzip" >> target
          # Bearer tokens in URLs stay out of the access log. A magic link, an
          # unsubscribe link, a guest pass: any run of 16+ URL-safe base64
          # characters standing as a whole path segment or a query value is
          # replaced, in the request line and in the two headers that carry the
          # referring page (Referer, and Hx-Current-Url from htmx). A token that
          # carries a file extension (a per-user calendar feed, a signed file
          # URL) is caught by the second alternative, which asks for 32+
          # characters so ordinary long file names stay readable. Fingerprinted
          # asset names have a dot before the hash, short parameters are short,
          # so neither matches. The same filter is on the default logger
          # (run-caddy.sh), which the request dumps in the error log go through.
          print "    log {" >> target
          print "        output file /var/log/caddy/access.log {" >> target
          print "            roll_size 20MiB" >> target
          print "            roll_keep 12" >> target
          print "            roll_keep_for 2160h" >> target
          print "        }" >> target
          print "        format filter {" >> target
          print "            wrap json" >> target
          print "            fields {" >> target
          print "                request>uri regexp ([/=])(?:[A-Za-z0-9_-]{16,}([/?&]|$)|[A-Za-z0-9_-]{32,}(\\.[A-Za-z0-9]{1,8}(?:[/?&]|$))) ${1}REDACTED${2}${3}" >> target
          print "                request>headers>Referer regexp ([/=])(?:[A-Za-z0-9_-]{16,}([/?&]|$)|[A-Za-z0-9_-]{32,}(\\.[A-Za-z0-9]{1,8}(?:[/?&]|$))) ${1}REDACTED${2}${3}" >> target
          print "                request>headers>Hx-Current-Url regexp ([/=])(?:[A-Za-z0-9_-]{16,}([/?&]|$)|[A-Za-z0-9_-]{32,}(\\.[A-Za-z0-9]{1,8}(?:[/?&]|$))) ${1}REDACTED${2}${3}" >> target
          print "            }" >> target
          print "        }" >> target
          print "    }" >> target
          # Access-log user attribution: forward_auth injects Remote-User on
          # protected routes; recording it gives a per-user access trail that
          # ships to the tamper-evident log bucket. Empty on public routes.
          print "    log_append user {http.request.header.Remote-User}" >> target
          # Security-header baseline for every site. ?-prefix sets a header
          # only when the app did not set its own, so apps can override. One
          # directive per header: inside a single header block Caddy folds the
          # four ?-conditions into one handler that fires only when ALL four
          # are absent, so an app setting one of them (Authelia, fellows) lost
          # the other three, HSTS included (2026-10-31 review).
          print "    header ?Strict-Transport-Security \"max-age=31536000; includeSubDomains\"" >> target
          print "    header ?X-Content-Type-Options nosniff" >> target
          print "    header ?Referrer-Policy strict-origin-when-cross-origin" >> target
          print "    header ?X-Frame-Options DENY" >> target
          # Static-asset caching. A *fingerprinted* asset URL changes whenever
          # its bytes change, so the browser may cache it forever and never
          # revalidate -- no round-trip, and on a gated app no repeat hit on the
          # forward_auth check (a warm asset never touches the network at all).
          # Two fingerprint conventions are honoured so any app can opt in with
          # whatever its stack already emits:
          #   * content hash in the filename -- app.9f3a1c2b.css
          #     (Vite / webpack / Django ManifestStaticFilesStorage, WhiteNoise),
          #     or a Hugo processed-image name -- photo_hu_9f3a1c2b4d5e6f70.webp
          #     (the hash covers the source bytes and the processing options)
          #   * a ?v= build tag -- coffee.css?v=9f3a1c2b (hand-rolled busting)
          # Both are scoped to static file extensions, so a *document* URL that
          # happens to carry ?v= is never frozen. "private" (not "public") keeps
          # gated assets out of any shared/CDN cache -- they stay per-browser.
          # ?-prefix defers to an app that sets its own Cache-Control. An app
          # that serves un-fingerprinted assets matches neither rule and keeps
          # its existing ETag revalidation, so this is a no-op until adopted.
          print "    @scaffold_static_hashed path_regexp (?:\\.[0-9a-f]{8,}|_hu_[0-9a-f]{12,16})\\.(?:css|js|mjs|woff2?|ttf|otf|svg|png|jpe?g|webp|avif|gif|ico)$" >> target
          print "    header @scaffold_static_hashed ?Cache-Control \"private, max-age=31536000, immutable\"" >> target
          print "    @scaffold_static_versioned {" >> target
          print "        query v=*" >> target
          print "        path *.css *.js *.mjs *.woff *.woff2 *.ttf *.otf *.svg *.png *.jpg *.jpeg *.webp *.avif *.gif *.ico" >> target
          print "    }" >> target
          print "    header @scaffold_static_versioned ?Cache-Control \"private, max-age=31536000, immutable\"" >> target
        }

        depth += opens - closes
        if (in_proxy && depth <= proxy_depth) {
          if (!seen_strip) {
            printf "ERROR: %s:%d: reverse_proxy block lacks import strip_auth_cookie (gateway session cookie would reach the app)\n", FILENAME, proxy_line > "/dev/stderr"
            bad = 1
          }
          in_proxy = 0
        }
        if (depth == 0) { target = "" }
        prev_trimmed = trimmed
      }
      END {
        if (depth != 0) {
          printf "ERROR: %s: unbalanced braces (depth %d at end of file)\n", FILENAME, depth > "/dev/stderr"
          bad = 1
        }
        if (bad) { exit 1 }
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
