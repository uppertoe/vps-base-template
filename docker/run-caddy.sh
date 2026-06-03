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

find /srv/repo/apps -mindepth 2 -maxdepth 2 -type f -name '*.caddy' | sort | while read -r snippet; do
  printf '\n' >> "$generated_config"
  awk '
    {
      line = $0
      trimmed = line
      opens = gsub(/\{/, "{", line)
      closes = gsub(/\}/, "}", line)
      sub(/^[[:space:]]*/, "", trimmed)

      print $0

      # Inject default response compression into each top-level site block.
      if (depth == 0 && line ~ /\{[[:space:]]*$/ && substr(trimmed, 1, 1) != "(") {
        print "    encode zstd gzip"
      }

      depth += opens - closes
    }
  ' "$snippet" >> "$generated_config"
  printf '\n' >> "$generated_config"
done

exec caddy run --config "$generated_config" --adapter caddyfile
