#!/bin/sh
set -eu

generated_config="/tmp/Caddyfile"

cp /etc/caddy/Caddyfile "$generated_config"

find /srv/repo/apps -mindepth 2 -maxdepth 2 -type f -name '*.caddy' | sort | while read -r snippet; do
  printf '\n' >> "$generated_config"
  cat "$snippet" >> "$generated_config"
  printf '\n' >> "$generated_config"
done

exec caddy run --config "$generated_config" --adapter caddyfile
