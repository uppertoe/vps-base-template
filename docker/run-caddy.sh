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
}

GLOBAL
} >> "$generated_config"
cat /etc/caddy/Caddyfile >> "$generated_config"
if [ -f /etc/caddy/apps.caddy ]; then
  cat /etc/caddy/apps.caddy >> "$generated_config"
fi

exec caddy run --config "$generated_config" --adapter caddyfile
