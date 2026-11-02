#!/usr/bin/env bash
set -euo pipefail

# The server repo root: this file is installed at <server>/scaffold/scripts/server/,
# so three levels up, unless the calling shim says otherwise.
ROOT_DIR="${SERVER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cd "$ROOT_DIR"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || fail "required file missing: $path"
}

require_contains() {
  local path="$1"
  local pattern="$2"
  grep -Fqx "$pattern" "$path" || fail "$path is missing expected line: $pattern"
}

require_not_contains() {
  local path="$1"
  local pattern="$2"
  if grep -Fq "$pattern" "$path"; then
    fail "$path contains forbidden text: $pattern"
  fi
}

require_file "docker-compose.yml"
require_file ".generated/caddy/apps.caddy"
require_file ".generated/caddy/networks.yml"
require_file ".env.example"
require_file "Caddyfile"
require_file "Caddyfile.local"
require_file "docker-compose.override.yml.example"
require_file "scripts/post-provision-smoke-test.sh"
require_file "scripts/provision.sh"
require_file "scripts/restore.sh"
require_file "scripts/check-server-files.sh"
require_file "scaffold/scripts/server/lib/orchestrate.sh"
require_file "apps/auth/docker-compose.yml"
require_file "apps/auth/auth.caddy"
require_file "apps/auth/.env.example"

require_contains "docker-compose.yml" "  - scaffold/docker/caddy.base.yml"
require_contains "docker-compose.yml" "  - .generated/caddy/networks.yml"
# apps/auth is enabled on most servers and shipped commented out by the
# template; either way the include line must be present, so turning the
# gateway on is a one-character change and never a forgotten app.
grep -qE '^  (# )?- apps/auth/docker-compose.yml$' docker-compose.yml \
  || fail "docker-compose.yml must list apps/auth/docker-compose.yml (live or commented)"
require_contains ".env.example" "DOMAIN=myserver.example.com"
require_contains "Caddyfile.local" "    local_certs"
require_contains "docker-compose.override.yml.example" "      - ./Caddyfile.local:/etc/caddy/Caddyfile:ro"
require_contains "scaffold/scripts/server/post-provision-smoke-test.sh" "check_remote \"deploy helper exists and is executable\" \"sudo test -x /home/deploy/deploy\""

require_not_contains "Caddyfile" "import /srv/repo/apps/*/*.caddy"
require_not_contains "Caddyfile.local" "import /srv/repo/apps/*/*.caddy"

# The committed bundle must match its sources (apps/, include list).
bash scripts/check-generated-sync.sh

# Repo tooling must at least parse — cheap insurance for the setup helpers.
# Include scripts/lib/*.sh (the non-recursive scripts/*.sh glob would skip it).
shopt -s nullglob
for f in scripts/*.sh scripts/lib/*.sh; do
  bash -n "$f" || fail "bash syntax error in $f"
done
shopt -u nullglob
for f in scripts/*.py; do
  python3 -m py_compile "$f" || fail "python syntax error in $f"
done

echo "Template consistency checks passed."
