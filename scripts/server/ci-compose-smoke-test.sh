#!/usr/bin/env bash
set -euo pipefail

# The server repo root: this file is installed at <server>/scaffold/scripts/server/,
# so three levels up, unless the calling shim says otherwise.
ROOT_DIR="${SERVER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cd "$ROOT_DIR"

COMPOSE_PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$ROOT_DIR")}"
TEST_APP_DIR="apps/ci-smoke"
CI_OVERRIDE_FILE="docker-compose.ci.override.yml"
BASE_COMPOSE=(docker compose -f docker-compose.yml -f "$CI_OVERRIDE_FILE")

cleanup() {
  "${BASE_COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$TEST_APP_DIR"
  # Re-render the committed bundle without the test app, restoring it to match
  # the repo's real sources.
  bash scaffold/docker/render-caddy-routes.sh >/dev/null 2>&1 || true
  rm -f .env docker-compose.override.yml "$CI_OVERRIDE_FILE"
  # Remove only the per-app .env stubs THIS run generated (a dev machine may
  # hold real ones, which must survive).
  if [[ -n "${GENERATED_APP_ENVS:-}" ]]; then
    # shellcheck disable=SC2086  # a space-separated list, split on purpose
    rm -f $GENERATED_APP_ENVS
  fi
  rm -f docker-compose.rehearsal.yml /tmp/ci-smoke-config-{old,new,static}.json /tmp/ci-audit-exceptions.json
  if [[ -n "${REHEARSAL_TREE:-}" ]]; then
    git worktree remove --force "$REHEARSAL_TREE" >/dev/null 2>&1 || true
    rm -rf "$REHEARSAL_TREE"
  fi
}

wait_for_caddy() {
  local attempts=0
  until "${BASE_COMPOSE[@]}" ps --status running --services | grep -qx "caddy"; do
    attempts=$((attempts + 1))
    if [[ "$attempts" -ge 20 ]]; then
      "${BASE_COMPOSE[@]}" logs caddy || true
      echo "caddy container failed to reach running state" >&2
      return 1
    fi
    sleep 1
  done
}

wait_for_caddy_healthy() {
  local attempts=0
  local container_id=""

  container_id="$("${BASE_COMPOSE[@]}" ps -q caddy)"
  if [[ -z "$container_id" ]]; then
    echo "caddy container id not found" >&2
    return 1
  fi

  until [[ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id")" == "healthy" ]]; do
    attempts=$((attempts + 1))
    if [[ "$attempts" -ge 30 ]]; then
      "${BASE_COMPOSE[@]}" logs caddy || true
      echo "caddy container failed to reach healthy state" >&2
      return 1
    fi
    sleep 1
  done
}

assert_http_redirect() {
  local expected_host="$1"
  local attempts=0
  local headers=""

  until headers="$(
    curl \
      --silent \
      --show-error \
      --fail \
      --head \
      --header "Host: ${expected_host}" \
      "http://127.0.0.1:18080/" \
      2>/dev/null
  )"; do
    attempts=$((attempts + 1))
    if [[ "$attempts" -ge 20 ]]; then
      "${BASE_COMPOSE[@]}" logs caddy || true
      echo "caddy did not redirect expected host ${expected_host}" >&2
      return 1
    fi
    sleep 1
  done

  grep -i -F "location: https://${expected_host}/" <<<"$headers" >/dev/null
}

assert_https_body() {
  local expected_host="$1"
  local attempts=0
  local body=""

  until body="$(
    curl \
      --silent \
      --show-error \
      --fail \
      --insecure \
      --resolve "${expected_host}:18443:127.0.0.1" \
      "https://${expected_host}:18443/" \
      2>/dev/null
  )"; do
    attempts=$((attempts + 1))
    if [[ "$attempts" -ge 20 ]]; then
      "${BASE_COMPOSE[@]}" logs caddy || true
      echo "caddy did not serve expected host ${expected_host} over HTTPS" >&2
      return 1
    fi
    sleep 1
  done

  [[ "$body" == "ci smoke ok" ]]
}

trap cleanup EXIT
cleanup

mkdir -p "$TEST_APP_DIR"
cat > .env <<'EOF'
DOMAIN=example.com
EOF

cat > "$CI_OVERRIDE_FILE" <<'EOF'
services:
  caddy:
    ports:
      - "18080:80"
      - "18443:443"
      - "18443:443/udp"
EOF

cat > "${TEST_APP_DIR}/ci-smoke.caddy" <<'EOF'
# scaffold-lint: public -- the CI smoke site answers one fixed string and exists only inside the CI job
ci.{$DOMAIN} {
    respond "ci smoke ok" 200
}
EOF

bash scaffold/docker/render-caddy-routes.sh

echo "Validating standard compose config"
"${BASE_COMPOSE[@]}" config >/dev/null

echo "Starting caddy with production config"
"${BASE_COMPOSE[@]}" up -d caddy >/dev/null
wait_for_caddy
wait_for_caddy_healthy
"${BASE_COMPOSE[@]}" exec -T caddy grep -F 'encode zstd gzip' /tmp/Caddyfile >/dev/null
# shellcheck disable=SC2016  # literal Caddy placeholder, not a shell variable
"${BASE_COMPOSE[@]}" exec -T caddy grep -F 'ci.{$DOMAIN}' /tmp/Caddyfile >/dev/null
assert_http_redirect "ci.example.com"

echo "Validating local override config"
cp docker-compose.override.yml.example docker-compose.override.yml
docker compose -f docker-compose.yml -f "$CI_OVERRIDE_FILE" -f docker-compose.override.yml config >/dev/null

echo "Restarting caddy with local override"
docker compose -f docker-compose.yml -f "$CI_OVERRIDE_FILE" -f docker-compose.override.yml up -d caddy >/dev/null
wait_for_caddy
wait_for_caddy_healthy
"${BASE_COMPOSE[@]}" exec -T caddy grep -F 'encode zstd gzip' /tmp/Caddyfile >/dev/null
"${BASE_COMPOSE[@]}" exec -T caddy grep -F 'local_certs' /tmp/Caddyfile >/dev/null
assert_https_body "ci.example.com"

echo "Booting the stock-image data tier with dummy env values"
# Compose interpolates ${VARS} from the project .env; the real values are
# gitignored secrets. Any var referenced by the compose files gets a dummy so
# the db/cache tier can actually BOOT in CI — the point is catching
# image-level breaking changes (e.g. postgres:18 relocating PGDATA, seen live
# 2026-07-10 after CI green-lit the bump), which need no real credentials.
grep -rhoE '\$\{[A-Za-z_][A-Za-z0-9_]*' docker-compose.yml apps/*/docker-compose.yml 2>/dev/null \
  | sed 's/^..//' | sort -u | while read -r var; do
    grep -q "^${var}=" .env || echo "${var}=cidummy0" >> .env
  done

# Services also read gitignored per-app .env files (env_file: required:false).
# Synthesize a stub from each app's .env.example — declared-but-empty vars get
# a dummy value — but only where no .env exists, so real ones survive locally.
# A data-tier container may read its own narrower file one level down (for
# example apps/roster-insights/db/.env), stubbed from an example beside it.
GENERATED_APP_ENVS=""
for example in apps/*/.env.example apps/*/*/.env.example; do
  [[ -f "$example" ]] || continue
  app_env="${example%.env.example}.env"
  [[ -f "$app_env" ]] && continue
  sed -E 's/^([A-Za-z_][A-Za-z0-9_]*)=$/\1=cidummy0/' "$example" > "$app_env"
  GENERATED_APP_ENVS="$GENERATED_APP_ENVS $app_env"
done

# The deployment's accepted-exceptions register is keyed by PROD container
# names (deploy-*); remap to this CI project's names so the same documented
# exceptions apply to the same services here, in both checks below.
python3 - "$COMPOSE_PROJECT" > /tmp/ci-audit-exceptions.json <<'PY'
import json, re, sys
import yaml
project = sys.argv[1]
try:
    with open("ansible/audit-exceptions.yml") as f:
        reg = yaml.safe_load(f) or {}
except FileNotFoundError:  # fresh template repos have no register yet
    reg = {}
exceptions = reg.get("audit_compose_exceptions", {}) or {}
print(json.dumps({re.sub(r"^deploy-", f"{project}-", name): controls
                  for name, controls in exceptions.items()}))
PY

# --- CIS Docker section 5, as declared -----------------------------------------
# The runtime check at the end of this script sees only the containers CI
# starts (Caddy and the data tier), so an app whose compose file lacks the
# section 5 block (non-root user, cap_drop ALL, no-new-privileges, read-only
# root, memory and pids limits, a healthcheck, a memory tier) would reach the
# live host before any audit noticed. The same checker reads the resolved
# compose config here and applies the same controls to every declared service.
echo "Checking CIS Docker section 5 controls declared in the compose files"
"${BASE_COMPOSE[@]}" config --format json > /tmp/ci-smoke-config-static.json
python3 scaffold/ansible/files/compose-audit/check-compose-hardening.py \
  --compose-config /tmp/ci-smoke-config-static.json \
  --compose-project "$COMPOSE_PROJECT" --exceptions /tmp/ci-audit-exceptions.json

# --- Database upgrade rehearsal (state-transition rigour) --------------------
# A db-image bump must prove the NEW image starts on data the OLD image wrote
# — booting fresh volumes proves only "vN+1 starts", which is how the pg18
# bump reached prod (2026-07-10). A red result on a database MAJOR is the
# honest signal (in-place major upgrades are typically impossible): plan the
# migration (dump -> new volume -> restore) before merging.
echo "Rehearsing database image upgrades against ${REHEARSAL_BASE_REF:-origin/main}"
REHEARSAL_BASE_REF="${REHEARSAL_BASE_REF:-origin/main}"
git rev-parse --verify -q "$REHEARSAL_BASE_REF" >/dev/null 2>&1 || git fetch -q origin main >/dev/null 2>&1 || true
if git rev-parse --verify -q "$REHEARSAL_BASE_REF" >/dev/null 2>&1; then
  REHEARSAL_TREE="$(mktemp -d)"
  rmdir "$REHEARSAL_TREE" && git worktree add -q --detach "$REHEARSAL_TREE" "$REHEARSAL_BASE_REF"
  # The worktree lacks the submodule + secrets; the include tree and env are
  # identical enough for config rendering.
  cp .env "$REHEARSAL_TREE/.env"
  rm -rf "$REHEARSAL_TREE/scaffold" && cp -R scaffold "$REHEARSAL_TREE/scaffold"
  "${BASE_COMPOSE[@]}" config --format json > /tmp/ci-smoke-config-new.json 2>/dev/null
  (cd "$REHEARSAL_TREE" && docker compose -f docker-compose.yml config --format json) \
    > /tmp/ci-smoke-config-old.json 2>/dev/null || echo '{}' > /tmp/ci-smoke-config-old.json

  rehearsal_pairs="$(python3 - /tmp/ci-smoke-config-old.json /tmp/ci-smoke-config-new.json <<'PY'
import json, sys
old = json.load(open(sys.argv[1])).get("services", {})
new = json.load(open(sys.argv[2])).get("services", {})
dbs = ("postgres:", "mariadb:", "mysql:", "mongo:")
for name, svc in sorted(new.items()):
    ni = str(svc.get("image", ""))
    oi = str(old.get(name, {}).get("image", ""))
    if ni.startswith(dbs) and oi.startswith(dbs) and oi != ni:
        print(f"{name} {oi} {ni}")
PY
)"

  while read -r svc old_img new_img; do
    [[ -z "$svc" ]] && continue
    echo "  rehearsing $svc: ${old_img%%@*} -> ${new_img%%@*}"
    cat > docker-compose.rehearsal.yml <<EOF
services:
  $svc:
    image: "$old_img"
EOF
    if ! docker compose -f docker-compose.yml -f "$CI_OVERRIDE_FILE" -f docker-compose.rehearsal.yml \
        up -d --wait --wait-timeout 120 "$svc"; then
      "${BASE_COMPOSE[@]}" logs --tail 25 "$svc" || true
      echo "rehearsal setup failed: old image did not become healthy on a fresh volume" >&2
      exit 1
    fi
    cid="$("${BASE_COMPOSE[@]}" ps -q "$svc")"
    marker_ok=false
    if [[ "$new_img" == postgres:* ]]; then
      pg_user="$(docker exec "$cid" printenv POSTGRES_USER 2>/dev/null || echo postgres)"
      pg_db="$(docker exec "$cid" printenv POSTGRES_DB 2>/dev/null || echo postgres)"
      docker exec "$cid" psql -q -U "$pg_user" -d "$pg_db" \
        -c "CREATE TABLE IF NOT EXISTS upgrade_rehearsal(marker text); INSERT INTO upgrade_rehearsal VALUES ('ci');" >/dev/null
      marker_ok=true
    fi
    rm -f docker-compose.rehearsal.yml
    if ! "${BASE_COMPOSE[@]}" up -d --wait --wait-timeout 120 "$svc"; then
      "${BASE_COMPOSE[@]}" logs --tail 25 "$svc" || true
      echo "UPGRADE REHEARSAL FAILED: $svc cannot start ${new_img%%@*} on data written by ${old_img%%@*}." >&2
      echo "In-place upgrades are typically impossible across database majors — plan a migration" >&2
      echo "(dump -> recreate volume on the new image -> restore) BEFORE merging this bump." >&2
      exit 1
    fi
    if [[ "$marker_ok" == "true" ]]; then
      cid="$("${BASE_COMPOSE[@]}" ps -q "$svc")"
      if ! docker exec "$cid" psql -q -U "$pg_user" -d "$pg_db" \
          -tAc "SELECT marker FROM upgrade_rehearsal LIMIT 1" 2>/dev/null | grep -q ci; then
        echo "UPGRADE REHEARSAL FAILED: $svc lost the marker row across the image change" >&2
        exit 1
      fi
    fi
    echo "  $svc: upgrade rehearsal OK (data survived ${old_img%%@*} -> ${new_img%%@*})"
  done <<<"$rehearsal_pairs"
  [[ -z "$rehearsal_pairs" ]] && echo "  (no database image changes vs base — skipped)"
else
  echo "  (base ref unavailable — rehearsal skipped)"
fi

data_manifest="$("${BASE_COMPOSE[@]}" config --format json 2>/dev/null | python3 -c "
import json, sys
cfg = json.load(sys.stdin)
dbs = ('postgres:', 'mariadb:', 'mysql:', 'mongo:')
caches = ('redis:', 'valkey:')
for name, svc in sorted(cfg.get('services', {}).items()):
    image = str(svc.get('image', ''))
    if image.startswith(dbs):
        print(f'{name} db')
    elif image.startswith(caches):
        print(f'{name} cache')
")"
data_services="$(awk '{print $1}' <<<"$data_manifest" | xargs)"
db_services="$(awk '$2 == "db" {print $1}' <<<"$data_manifest" | xargs)"

if [[ -n "$data_services" ]]; then
  # shellcheck disable=SC2086  # a space-separated list, split on purpose
  echo "Data-tier services under test:" $data_services
  # shellcheck disable=SC2086
  if ! "${BASE_COMPOSE[@]}" up -d --wait --wait-timeout 120 $data_services; then
    for svc in $data_services; do
      echo "--- logs: $svc"
      "${BASE_COMPOSE[@]}" logs --tail 30 "$svc" || true
    done
    echo "data-tier service failed to become healthy" >&2
    exit 1
  fi

  # A healthy database is not enough: postgres:18 taught us (live,
  # 2026-07-10) that an image relocating its data directory can boot fine
  # while writing the data somewhere that does not survive a container
  # recreate (an anonymous volume, or — with newer builds that drop the
  # image VOLUME — the container layer itself). Resolve each database's real
  # data directory and require it to live on a NAMED volume.
  for svc in $db_services; do
    cid="$("${BASE_COMPOSE[@]}" ps -q "$svc")"
    data_dir="$(docker exec "$cid" sh -c 'printenv PGDATA' 2>/dev/null || true)"
    if [[ -z "$data_dir" ]]; then
      case "$(docker inspect "$cid" --format '{{.Config.Image}}')" in
        mysql*|mariadb*) data_dir=/var/lib/mysql ;;
        mongo*)          data_dir=/data/db ;;
        *)               data_dir=/var/lib/postgresql/data ;;
      esac
    fi
    if ! MOUNTS_JSON="$(docker inspect "$cid" --format '{{json .Mounts}}')" \
         SVC="$svc" DATA_DIR="$data_dir" python3 - <<'PY'
import json, os, re, sys
mounts = json.loads(os.environ["MOUNTS_JSON"])
data_dir = os.environ["DATA_DIR"].rstrip("/") + "/"
best, best_len = None, -1
for m in mounts:
    dest = m["Destination"].rstrip("/") + "/"
    if data_dir.startswith(dest) and len(dest) > best_len:
        best, best_len = m, len(dest)
named = bool(best) and best.get("Type") == "volume" \
    and not re.fullmatch(r"[0-9a-f]{64}", best.get("Name", "") or "")
if not named:
    where = (f"mount {best['Destination']} ({best['Type']} {best.get('Name', '')})"
             if best else "the container layer (no covering mount)")
    print(f"{os.environ['SVC']}: data dir {os.environ['DATA_DIR']} lives on {where}, "
          f"not a named volume", file=sys.stderr)
    sys.exit(1)
PY
    then
      echo "database data directory is not on a named volume — data would not survive a recreate" >&2
      exit 1
    fi
    echo "  $svc: data dir $data_dir on a named volume"
  done
fi

echo "Verifying CIS Docker section 5 runtime controls on the running stack"
python3 scaffold/ansible/files/compose-audit/check-compose-hardening.py \
  --compose-project "$COMPOSE_PROJECT" --exceptions /tmp/ci-audit-exceptions.json
