#!/bin/sh
set -eu

generated_config="/tmp/Caddyfile"

# If ACME_EMAIL is set, emit a Caddy global options block with the Let's Encrypt
# contact email FIRST (global options must precede all site blocks). Without a
# valid email Caddy registers the ACME account with a bogus "default" contact,
# which Let's Encrypt rejects (invalidContact). Comments may precede it.
: > "$generated_config"
if [ -n "${ACME_EMAIL:-}" ]; then
  printf '{\n\temail %s\n}\n\n' "$ACME_EMAIL" >> "$generated_config"
fi
cat /etc/caddy/Caddyfile >> "$generated_config"
if [ -f /etc/caddy/apps.caddy ]; then
  cat /etc/caddy/apps.caddy >> "$generated_config"
fi

exec caddy run --config "$generated_config" --adapter caddyfile
