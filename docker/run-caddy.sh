#!/bin/sh
set -eu

generated_config="/tmp/Caddyfile"

cp /etc/caddy/Caddyfile "$generated_config"

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
