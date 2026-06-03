#!/bin/sh
set -eu

generated_config="/tmp/Caddyfile"
snippets="$(mktemp)"   # (name) { ... } definitions — must precede any import
sites="$(mktemp)"      # site blocks

# If ACME_EMAIL is set, emit a Caddy global options block with the Let's Encrypt
# contact email FIRST (global options must precede all site blocks). Without a
# valid email Caddy registers the ACME account with a bogus "default" contact,
# which Let's Encrypt rejects (invalidContact). Comments may precede it.
: > "$generated_config"
if [ -n "${ACME_EMAIL:-}" ]; then
  printf '{\n\temail %s\n}\n\n' "$ACME_EMAIL" >> "$generated_config"
fi
cat /etc/caddy/Caddyfile >> "$generated_config"

# Assemble all apps/*/*.caddy. Caddy resolves `import <snippet>` in file order,
# so every `(snippet)` DEFINITION must come before any site block that imports it
# (e.g. apps using `import protected` defined in apps/auth/auth.caddy, which would
# otherwise sort later). Route top-level snippet blocks and site blocks to
# separate buffers and emit snippets first.
find /srv/repo/apps -mindepth 2 -maxdepth 2 -type f -name '*.caddy' | sort | while read -r snippet; do
  awk -v snip="$snippets" -v site="$sites" '
    {
      line = $0
      trimmed = line
      opens = gsub(/\{/, "{", line)
      closes = gsub(/\}/, "}", line)
      sub(/^[[:space:]]*/, "", trimmed)

      # At the start of a top-level block, pick the buffer: snippet defs begin
      # with "(", everything else is a site block.
      if (depth == 0 && target == "") {
        target = (substr(trimmed, 1, 1) == "(") ? snip : site
      }

      print $0 >> target

      # Inject default response compression into each top-level site block.
      if (depth == 0 && target == site && line ~ /\{[[:space:]]*$/ && substr(trimmed, 1, 1) != "(") {
        print "    encode zstd gzip" >> target
      }

      depth += opens - closes
      if (depth == 0) { target = "" }
    }
  ' "$snippet"
  printf '\n' >> "$snippets"
  printf '\n' >> "$sites"
done

cat "$snippets" "$sites" >> "$generated_config"
rm -f "$snippets" "$sites"

exec caddy run --config "$generated_config" --adapter caddyfile
