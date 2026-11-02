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
#   route-access.tsv -- each site's access rules, one "host<TAB>kind<TAB>value"
#                    line each (kind: groups, domains, signed-in, guests,
#                    network -- open on a named network via an
#                    "import <name>_network" snippet -- or public with the
#                    marker's reason; an open path beside a gate, declared
#                    with "# scaffold-lint: open-path -- <paths>: <why>", is a
#                    public row whose value is "<paths>: <why>"). The auth
#                    service shows it as a "who can reach what" table.
#   route-groups.tsv -- every gateway group a site's guard requires, one
#                    "group<TAB>host" line each, and every group an app
#                    declares it reads itself with
#                    "# scaffold-groups: <groups> -- <why>", as
#                    "group<TAB>host<TAB>declared". Mounted read-only into the
#                    auth service, whose Groups page lists the groups the
#                    routes use so administrators pick names instead of typing
#                    them, and which refuses a declared group as a break-glass
#                    target.
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
groups_file="$out_dir/route-groups.tsv"
access_file="$out_dir/route-access.tsv"
snippets="$(mktemp)"
sites="$(mktemp)"

cleanup() {
  rm -f "$snippets" "$sites"
}
trap cleanup EXIT

mkdir -p "$out_dir"
: > "$snippets"
: > "$sites"

for f in "$routes_file" "$networks_file" "$groups_file" "$access_file"; do
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

        # Every site must declare who may reach it: import one of the gateway
        # guards (protected*, auth_gate*) or forward_auth somewhere in the
        # block, or carry the marker
        #   # scaffold-lint: public -- <why this site is open to everyone>
        # on a comment line just above the site address or inside the block.
        # A site with neither fails the render, so a forgotten gate on a new
        # app cannot reach a deployment unnoticed.
        if (depth == 0) {
          if (substr(trimmed, 1, 1) == "#") {
            if (trimmed ~ /scaffold-lint: public/) { pending_public = 1 }
            if (trimmed ~ /scaffold-lint: open-path/) {
              printf "ERROR: %s:%d: an open-path marker belongs inside a site block, inside or just above the handle it describes\n", FILENAME, FNR > "/dev/stderr"
              bad = 1
            }
          } else if (trimmed != "" && !(line ~ /\{[[:space:]]*$/ && substr(trimmed, 1, 1) != "(")) {
            pending_public = 0
          }
        }
        if (depth == 0 && target == site && line ~ /\{[[:space:]]*$/ && substr(trimmed, 1, 1) != "(") {
          in_site = 1; site_line = FNR; site_addr = trimmed; sub(/[[:space:]]*\{[[:space:]]*$/, "", site_addr)
          site_declared = pending_public; site_guarded = 0; pending_public = 0
        } else if (in_site && depth > 0) {
          if (trimmed ~ /^import (protected|auth_gate)/ || trimmed ~ /^forward_auth([[:space:]]|$)/) { site_guarded = 1 }
          if (substr(trimmed, 1, 1) == "#" && trimmed ~ /scaffold-lint: public/) { site_declared = 1 }
        }

        # Open paths beside a gate. In a site that has a guard, every handle,
        # handle_path or route block that serves something itself (a
        # reverse_proxy, file_server or respond line) must be guarded, by a
        # guard import or forward_auth inside it, in a route block nested in
        # it, or in an enclosing block, or it must carry the marker
        #   # scaffold-lint: open-path -- <paths>: <why these paths are open>
        # inside the block or on the comment line just above it (a named
        # matcher may sit between). route-access.tsv lists the marker as a
        # public row, so the "who can reach what" table shows the open paths
        # of a gated site and not only its gate. A comment line never counts
        # as code, and a handle_errors block is not a door. The check is
        # settled when the site block closes, once it is known whether the
        # site has a guard at all; a site with no guard is covered by the
        # public marker above.
        if (in_site && depth > 0) {
          if (substr(trimmed, 1, 1) == "#") {
            if (trimmed ~ /scaffold-lint: open-path/) {
              marker_text = trimmed; sub(/.*scaffold-lint: open-path[[:space:]]*(--)?[[:space:]]*/, "", marker_text)
              if (marker_text !~ /^[^:]+:[[:space:]]*[^[:space:]]/) {
                printf "ERROR: %s:%d: the marker must read \"# scaffold-lint: open-path -- <paths>: <reason>\"\n", FILENAME, FNR > "/dev/stderr"
                bad = 1
              }
              pending_open = 1; site_declared = 1
            }
          } else if (trimmed ~ /^(handle|handle_path|route|handle_errors)([[:space:]]|\{)/ && line ~ /\{[[:space:]]*$/) {
            nframes++
            frame_depth[nframes] = depth; frame_line[nframes] = FNR
            frame_route[nframes] = (trimmed ~ /^route/)
            frame_code[nframes] = 0; frame_guard[nframes] = 0
            frame_marker[nframes] = pending_open; pending_open = 0
            frame_exempt[nframes] = (trimmed ~ /^handle_errors/) || (nframes > 1 && frame_exempt[nframes - 1])
          } else if (trimmed != "" && substr(trimmed, 1, 1) != "@") {
            if (pending_open) {
              if (nframes > 0) { frame_marker[nframes] = 1 }
              pending_open = 0
            }
            if (nframes > 0) {
              if (trimmed ~ /^(reverse_proxy|file_server|respond)([[:space:]]|\{|$)/) { frame_code[nframes] = 1 }
              if (trimmed ~ /^import (protected|auth_gate)/ || trimmed ~ /^forward_auth([[:space:]]|$)/) { frame_guard[nframes] = 1 }
            }
          }
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
          # replaced, in the request line, in the two headers that carry the
          # referring page (Referer, and Hx-Current-Url from htmx) and in the
          # Location header of a redirect, which carries the gated URL a
          # signed-out person asked for and, after sign-in, where they were
          # sent. A token that carries a file extension (a per-user calendar
          # feed, a signed file URL) is caught by the second alternative, which
          # asks for 32+ characters so ordinary long file names stay readable.
          # The delimiters are accepted percent-encoded as well (%2F %3D before,
          # %2F %3F %26 after), because the login redirect carries the asked-for
          # URL encoded inside its rd= value. Fingerprinted asset names have a
          # dot before the hash, short parameters are short, so neither
          # matches. The same filter is on the default logger (run-caddy.sh),
          # which the request dumps in the error log go through; the offline
          # test in docker/tests/test-render-caddy-routes.sh keeps the two
          # identical and checks the token shapes above.
          print "    log {" >> target
          print "        output file /var/log/caddy/access.log {" >> target
          print "            roll_size 20MiB" >> target
          print "            roll_keep 12" >> target
          print "            roll_keep_for 2160h" >> target
          print "        }" >> target
          print "        format filter {" >> target
          print "            wrap json" >> target
          print "            fields {" >> target
          print "                request>uri regexp ([/=]|%2[Ff]|%3[Dd])(?:[A-Za-z0-9_-]{16,}([/?&]|%2[Ff]|%3[Ff]|%26|$)|[A-Za-z0-9_-]{32,}(\\.[A-Za-z0-9]{1,8}(?:[/?&]|%2[Ff]|%3[Ff]|%26|$))) ${1}REDACTED${2}${3}" >> target
          print "                request>headers>Referer regexp ([/=]|%2[Ff]|%3[Dd])(?:[A-Za-z0-9_-]{16,}([/?&]|%2[Ff]|%3[Ff]|%26|$)|[A-Za-z0-9_-]{32,}(\\.[A-Za-z0-9]{1,8}(?:[/?&]|%2[Ff]|%3[Ff]|%26|$))) ${1}REDACTED${2}${3}" >> target
          print "                request>headers>Hx-Current-Url regexp ([/=]|%2[Ff]|%3[Dd])(?:[A-Za-z0-9_-]{16,}([/?&]|%2[Ff]|%3[Ff]|%26|$)|[A-Za-z0-9_-]{32,}(\\.[A-Za-z0-9]{1,8}(?:[/?&]|%2[Ff]|%3[Ff]|%26|$))) ${1}REDACTED${2}${3}" >> target
          print "                resp_headers>Location regexp ([/=]|%2[Ff]|%3[Dd])(?:[A-Za-z0-9_-]{16,}([/?&]|%2[Ff]|%3[Ff]|%26|$)|[A-Za-z0-9_-]{32,}(\\.[A-Za-z0-9]{1,8}(?:[/?&]|%2[Ff]|%3[Ff]|%26|$))) ${1}REDACTED${2}${3}" >> target
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
        while (nframes > 0 && depth <= frame_depth[nframes]) {
          covered = frame_guard[nframes] || frame_marker[nframes] || frame_exempt[nframes]
          for (k = 1; k < nframes && !covered; k++) { if (frame_guard[k] || frame_marker[k]) { covered = 1 } }
          if (frame_code[nframes] && !covered) { nopen++; open_line[nopen] = frame_line[nframes] }
          # A route block runs its directives and falls through, so a guard
          # inside it also guards what follows in the enclosing block. A
          # handle block answers only the requests it matched, so its guard
          # says nothing about its siblings.
          if (nframes > 1 && frame_route[nframes] && frame_guard[nframes]) { frame_guard[nframes - 1] = 1 }
          nframes--
        }
        if (depth == 0 && in_site && FNR != site_line) {
          if (!site_guarded && !site_declared) {
            printf "ERROR: %s:%d: site %s declares no access: import a gateway guard, or mark it public with a comment \"# scaffold-lint: public -- <reason>\"\n", FILENAME, site_line, site_addr > "/dev/stderr"
            bad = 1
          }
          if (site_guarded) {
            for (k = 1; k <= nopen; k++) {
              printf "ERROR: %s:%d: site %s has a gate, but this block serves without one: import a gateway guard, or declare the open path with a comment \"# scaffold-lint: open-path -- <paths>: <reason>\" so route-access.tsv lists it\n", FILENAME, open_line[k], site_addr > "/dev/stderr"
              bad = 1
            }
          }
          nopen = 0; nframes = 0; pending_open = 0
          in_site = 0
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

# --- route-groups.tsv: the gateway groups each site's guard requires --------
# Recognises the guard snippets by name (apps/auth/auth.caddy) and a policy
# written out by hand (auth_gate "...", header_up X-Auth-Policy "..."). The
# host is the enclosing site block's address, with {$DOMAIN} left in place for
# the auth service to fill in. Domain-only guards name no group and add nothing.
{
  printf '# Generated by scaffold/docker/render-caddy-routes.sh; do not edit.\n'
  printf '# Gateway groups required by each site, one "group<TAB>host" per line; a group\n'
  printf '# the app reads itself (a scaffold-groups marker) has "declared" as a third field.\n'
  if [[ -d "$repo_root/apps" ]]; then
    find "$repo_root/apps" -mindepth 2 -maxdepth 2 -type f -name '*.caddy' | sort \
      | while IFS= read -r snippet; do
          awk '
            # A guard group is two columns; a group the app reads itself (a
            # scaffold-groups marker) carries "declared" as a third column,
            # so the auth service can tell the admin group of an application
            # from a route gate and refuse it as a break-glass target.
            function emit(list, tag,    n, parts, i) {
              n = split(list, parts, /[ ,]+/)
              for (i = 1; i <= n; i++) {
                if (parts[i] != "" && site != "") {
                  if (tag != "") { printf "%s\t%s\t%s\n", parts[i], site, tag } else { printf "%s\t%s\n", parts[i], site }
                }
              }
            }
            # groups=... field of an X-Auth-Policy string
            function policy_groups(policy,    n, fields, i) {
              n = split(policy, fields, ";")
              for (i = 1; i <= n; i++) {
                if (fields[i] ~ /^[[:space:]]*groups=/) { sub(/^[[:space:]]*groups=/, "", fields[i]); emit(fields[i]) }
              }
            }
            # the k-th double-quoted argument on the line
            function quoted(line, k,    n, parts) {
              n = split(line, parts, "\"")
              return (2 * k <= n) ? parts[2 * k] : ""
            }
            {
              line = $0
              trimmed = line
              sub(/^[[:space:]]*/, "", trimmed)
              # "# scaffold-groups: a b -- <why>" declares groups the app
              # reads from Remote-Groups itself (an admin page, say), so the
              # auth service does not call them unused. Above the site
              # address or inside its block.
              if (substr(trimmed, 1, 1) == "#") {
                if (trimmed ~ /scaffold-groups:/) {
                  declared = trimmed
                  sub(/.*scaffold-groups:[[:space:]]*/, "", declared)
                  sub(/[[:space:]]*--.*$/, "", declared)
                  if (depth == 0) { pending_groups = declared } else { emit(declared, "declared") }
                }
                next
              }
              if (depth == 0 && line ~ /\{[[:space:]]*$/) {
                if (substr(trimmed, 1, 1) == "(") {
                  site = ""
                } else {
                  site = trimmed
                  sub(/[[:space:]]*\{[[:space:]]*$/, "", site)
                  gsub(/[[:space:]]*,[[:space:]]*/, ",", site)
                  if (pending_groups != "") { emit(pending_groups, "declared") }
                }
                pending_groups = ""
              } else if (depth == 0 && trimmed != "") {
                pending_groups = ""
              }
              if (site != "") {
                if (trimmed ~ /^import protected_groups[[:space:]]/)            { emit(quoted(trimmed, 1)) }
                else if (trimmed ~ /^import protected_access(_gate)?[[:space:]]/) { emit(quoted(trimmed, 2)) }
                else if (trimmed ~ /^import protected_admin([[:space:]]|$)/)   { emit("admin") }
                else if (trimmed ~ /^import auth_gate(_labeled|_alt)?[[:space:]]/) { policy_groups(quoted(trimmed, 1)) }
                else if (trimmed ~ /^header_up X-Auth-Policy[[:space:]]/)      { policy_groups(quoted(trimmed, 1)) }
              }
              opens = gsub(/\{/, "{", line)
              closes = gsub(/\}/, "}", line)
              depth += opens - closes
              if (depth == 0) { site = "" }
            }
          ' "$snippet"
        done | sort -u
  fi
} > "$groups_file.tmp"
mv "$groups_file.tmp" "$groups_file"

# --- route-access.tsv: who can reach each site --------------------------------
# Same recognition as route-groups.tsv, plus domain lists, the plain
# "any signed-in user" guards, the public marker the render lint requires and
# the open-path marker it requires on an unguarded handle in a gated site.
# A site can apply different rules to different paths; every rule found in the
# block is listed against the site.
{
  printf '# Generated by scaffold/docker/render-caddy-routes.sh; do not edit.\n'
  printf '# Access rules per site, one "host<TAB>kind<TAB>value" per line.\n'
  if [[ -d "$repo_root/apps" ]]; then
    find "$repo_root/apps" -mindepth 2 -maxdepth 2 -type f -name '*.caddy' | sort \
      | while IFS= read -r snippet; do
          awk '
            function rule(kind, value) { if (site != "") { printf "%s\t%s\t%s\n", site, kind, value } }
            function quoted(line, k,    n, parts) {
              n = split(line, parts, "\"")
              return (2 * k <= n) ? parts[2 * k] : ""
            }
            function norm(list) { gsub(/[ ,]+/, " ", list); sub(/^ /, "", list); sub(/ $/, "", list); return list }
            function policy(p,    n, fields, i, f) {
              if (p ~ /^[[:space:]]*any([;[:space:]]|$)/) { rule(p ~ /guests=allow/ ? "guests" : "signed-in", "") ; return }
              n = split(p, fields, ";")
              for (i = 1; i <= n; i++) {
                f = fields[i]; sub(/^[[:space:]]*/, "", f)
                if (f ~ /^groups=/)  { sub(/^groups=/, "", f);  rule("groups", norm(f)) }
                if (f ~ /^domains=/) { sub(/^domains=/, "", f); rule("domains", norm(f)) }
              }
            }
            {
              line = $0
              trimmed = line
              sub(/^[[:space:]]*/, "", trimmed)
              if (substr(trimmed, 1, 1) == "#") {
                if (trimmed ~ /scaffold-lint: public/) {
                  reason = trimmed; sub(/.*scaffold-lint: public[[:space:]]*(--)?[[:space:]]*/, "", reason)
                  if (depth == 0) { pending = reason; has_pending = 1 } else { rule("public", reason) }
                }
                # An open path beside a gate: "<paths>: <why>" as a public row.
                if (trimmed ~ /scaffold-lint: open-path/ && depth > 0) {
                  reason = trimmed; sub(/.*scaffold-lint: open-path[[:space:]]*(--)?[[:space:]]*/, "", reason)
                  rule("public", reason)
                }
                next
              }
              if (depth == 0 && line ~ /\{[[:space:]]*$/) {
                if (substr(trimmed, 1, 1) == "(") {
                  site = ""
                } else {
                  site = trimmed
                  sub(/[[:space:]]*\{[[:space:]]*$/, "", site)
                  gsub(/[[:space:]]*,[[:space:]]*/, ",", site)
                  if (has_pending) { rule("public", pending) }
                }
                has_pending = 0
              } else if (depth == 0 && trimmed != "") {
                has_pending = 0
              }
              if (site != "") {
                if (trimmed ~ /^import [a-z0-9-]+_network([[:space:]]|$)/)           { n = trimmed; sub(/^import /, "", n); sub(/_network.*/, "", n); rule("network", n) }
                else if (trimmed ~ /^import protected[[:space:]]/)                  { rule("signed-in", "") }
                else if (trimmed ~ /^import protected_open([[:space:]]|$)/)          { rule("guests", "") }
                else if (trimmed ~ /^import protected_groups[[:space:]]/)            { rule("groups", norm(quoted(trimmed, 1))) }
                else if (trimmed ~ /^import protected_admin([[:space:]]|$)/)         { rule("groups", "admin") }
                else if (trimmed ~ /^import protected_access(_gate)?[[:space:]]/)    { rule("domains", norm(quoted(trimmed, 1))); rule("groups", norm(quoted(trimmed, 2))) }
                else if (trimmed ~ /^import protected_domains[a-z_]*[[:space:]]/)    { rule("domains", norm(quoted(trimmed, 1))) }
                else if (trimmed ~ /^import auth_gate(_labeled|_alt)?[[:space:]]/)  { policy(quoted(trimmed, 1)) }
                else if (trimmed ~ /^header_up X-Auth-Policy[[:space:]]/)            { policy(quoted(trimmed, 1)) }
              }
              opens = gsub(/\{/, "{", line)
              closes = gsub(/\}/, "}", line)
              depth += opens - closes
              if (depth == 0) { site = "" }
            }
          ' "$snippet"
        done | sort -u
  fi
} > "$access_file.tmp"
mv "$access_file.tmp" "$access_file"

echo "Rendered $routes_file"
echo "Rendered $networks_file"
echo "Rendered $groups_file"
echo "Rendered $access_file"
