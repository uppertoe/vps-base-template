#!/bin/sh
set -eu

generated_config="/tmp/Caddyfile"

# The Caddy global options block goes FIRST (it must precede all site blocks;
# comments may precede it). If ACME_EMAIL is set it carries the Let's Encrypt
# contact email: without a valid email Caddy registers the ACME account with a
# bogus "default" contact, which Let's Encrypt rejects (invalidContact).
#
# It always carries the token filter on the default logger, the one Caddy's
# own messages and the HTTP error log write to: an error entry dumps the whole
# request, so a failed request for a magic link, an unsubscribe link or a guest
# pass would otherwise put that bearer token on stdout, into journald and into
# the shipped logs. Same rule as the access log (render-caddy-routes.sh): a
# 16+ character URL-safe base64 path segment or query value becomes REDACTED,
# in the request line, the Referer and htmx's Hx-Current-Url.
: > "$generated_config"

# The mounted Caddyfile may open with a global options block of its own
# (Caddyfile.local is exactly `{ local_certs }`, mounted over the production
# file by docker-compose.override.yml and the CI smoke test). Caddy accepts one
# key-less block, and ours has to be first, so a leading block is split off
# here and its options folded into ours; whatever follows it is appended as
# the site configuration. Brace depth is tracked so a nested block inside the
# global one (a `log { … }`) does not end it early.
mounted_config="/etc/caddy/Caddyfile"
mounted_globals="/tmp/Caddyfile.globals"
mounted_sites="/tmp/Caddyfile.sites"
awk -v globals="$mounted_globals" -v sites="$mounted_sites" '
  state == 0 && /^[[:space:]]*(#|$)/ { print > sites; next }
  state == 0 && /^[[:space:]]*\{[[:space:]]*$/ { state = 1; depth = 1; next }
  state == 0 { state = 2 }
  state == 1 {
    line = $0
    depth += gsub(/\{/, "{", line) - gsub(/\}/, "}", line)
    if (depth == 0) { state = 2; next }
    print > globals
    next
  }
  { print > sites }
' "$mounted_config"
[ -f "$mounted_globals" ] || : > "$mounted_globals"
[ -f "$mounted_sites" ] || : > "$mounted_sites"

{
  printf '{\n'
  if [ -n "${ACME_EMAIL:-}" ]; then
    printf '\temail %s\n' "$ACME_EMAIL"
  fi
  cat <<'GLOBAL'
	log {
		format filter {
			wrap json
			fields {
				request>uri regexp ([/=])[A-Za-z0-9_-]{16,}([/?&]|$) ${1}REDACTED${2}
				request>headers>Referer regexp ([/=])[A-Za-z0-9_-]{16,}([/?&]|$) ${1}REDACTED${2}
				request>headers>Hx-Current-Url regexp ([/=])[A-Za-z0-9_-]{16,}([/?&]|$) ${1}REDACTED${2}
			}
		}
	}
GLOBAL
  cat "$mounted_globals"
  printf '}\n\n'
} >> "$generated_config"
cat "$mounted_sites" >> "$generated_config"
if [ -f /etc/caddy/apps.caddy ]; then
  cat /etc/caddy/apps.caddy >> "$generated_config"
fi

exec caddy run --config "$generated_config" --adapter caddyfile
