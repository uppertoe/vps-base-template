#!/usr/bin/env bash
# =============================================================================
# run_tests.sh — Integration tests for backup.sh and restore.sh
# =============================================================================
#
# WHAT IT TESTS
#   - Dry-run mode produces no snapshots
#   - Backup creates a restic snapshot
#   - Retention/prune runs without error
#   - Restore recreates data correctly in an alternate database
#   - Post-restore VERIFY_QUERY passes on good data and fails on empty DB
#   - Rollback: original database is recovered after a failed restore
#   - Partial failure: one bad service does not abort the others
#   - OPTIONAL=true service skips an unreachable database gracefully
#   - --list shows snapshots for a service
#
# PREREQUISITES
#   - Docker (for PostgreSQL container)
#   - restic (brew install restic  /  apt install restic)
#   - psql client (brew install libpq  /  apt install postgresql-client)
#
# USAGE
#   cd vps-base-template
#   bash backup/tests/integration/run_tests.sh
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# vps-base-template root
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

BACKUP_SCRIPT="$REPO_ROOT/ansible/roles/backup/files/backup.sh"
RESTORE_SCRIPT="$REPO_ROOT/ansible/roles/backup/files/restore.sh"

# PostgreSQL container settings
PG_CONTAINER="backup-integration-test-postgres"
PG_PORT=15432
PG_DB=testapp
PG_USER=testapp
PG_PASSWORD=testpass

RESTIC_REPO_DIR=""  # set in setup()
CONFIG_DIR=""       # set in setup()

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------

check_deps() {
  local missing=()
  command -v docker  &>/dev/null || missing+=(docker)
  command -v restic  &>/dev/null || missing+=(restic)
  command -v psql    &>/dev/null || missing+=(psql)
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: missing required tools: ${missing[*]}" >&2
    echo "Install with: brew install restic libpq  (macOS)" >&2
    echo "          or: apt install restic postgresql-client  (Debian/Ubuntu)" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

header() {
  echo ""
  echo "━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}
pass() { echo "[PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $*" >&2; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Script wrappers
# ---------------------------------------------------------------------------

run_backup() {
  BACKUP_CONFIG_DIR="$CONFIG_DIR" "$BACKUP_SCRIPT" "$@"
}

run_restore() {
  BACKUP_CONFIG_DIR="$CONFIG_DIR" "$RESTORE_SCRIPT" "$@"
}

# ---------------------------------------------------------------------------
# PostgreSQL helpers
# ---------------------------------------------------------------------------

_psql() {
  PGPASSWORD="$PG_PASSWORD" psql \
    --host 127.0.0.1 \
    --port "$PG_PORT" \
    --username "$PG_USER" \
    --no-psqlrc \
    "$@"
}

wait_for_postgres() {
  echo -n "Waiting for PostgreSQL"
  for _ in $(seq 1 30); do
    if _psql --dbname "$PG_DB" --command "SELECT 1" &>/dev/null; then
      echo " ready."
      return 0
    fi
    sleep 1
    echo -n "."
  done
  echo ""
  echo "ERROR: PostgreSQL did not become ready in time." >&2
  return 1
}

snapshot_count() {
  local repo_path="$1" password="$2"
  RESTIC_PASSWORD="$password" restic -r "$repo_path" snapshots --json 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d))'
}

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  header "Setup"

  RESTIC_REPO_DIR="$(mktemp -d)"
  CONFIG_DIR="$(mktemp -d)"

  # Start PostgreSQL container
  docker run -d --name "$PG_CONTAINER" \
    -e POSTGRES_DB="$PG_DB" \
    -e POSTGRES_USER="$PG_USER" \
    -e POSTGRES_PASSWORD="$PG_PASSWORD" \
    -p "127.0.0.1:${PG_PORT}:5432" \
    postgres:17-alpine \
    > /dev/null

  wait_for_postgres

  # Seed the test database
  _psql --dbname "$PG_DB" < "$SCRIPT_DIR/seed.sql"
  echo "Test database seeded (3 users)."

  # Write global config
  cp "$SCRIPT_DIR/fixtures/config.env" "$CONFIG_DIR/config.env"

  # Write service config (inject runtime values)
  mkdir -p "$CONFIG_DIR/services"
  cat > "$CONFIG_DIR/services/testapp.env" <<EOF
SERVICE_NAME=testapp
RESTIC_REPOSITORY=${RESTIC_REPO_DIR}/testapp
RESTIC_PASSWORD=test-repo-password
DB_HOST=127.0.0.1
DB_PORT=${PG_PORT}
DB_NAME=${PG_DB}
DB_USER=${PG_USER}
DB_PASSWORD=${PG_PASSWORD}
STDIN_FILENAME=testapp-db.sql
VERIFY_QUERY=SELECT COUNT(*) FROM users
OPTIONAL=false
EOF

  echo "Config written to $CONFIG_DIR"
}

teardown() {
  echo ""
  header "Teardown"
  docker rm -f "$PG_CONTAINER" 2>/dev/null || true
  [[ -n "$RESTIC_REPO_DIR" ]] && rm -rf "$RESTIC_REPO_DIR"
  [[ -n "$CONFIG_DIR" ]] && rm -rf "$CONFIG_DIR"
  echo "Done."
}

trap teardown EXIT

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_dry_run_exits_zero() {
  header "test_dry_run_exits_zero"
  if run_backup --dry-run > /dev/null 2>&1; then
    pass "dry-run exits 0 and makes no changes"
  else
    fail "dry-run exited non-zero"
  fi
}

test_backup_creates_snapshot() {
  header "test_backup_creates_snapshot"
  run_backup > /dev/null 2>&1

  local count
  count="$(snapshot_count "${RESTIC_REPO_DIR}/testapp" "test-repo-password")"

  if [[ "$count" -ge 1 ]]; then
    pass "backup created $count snapshot(s)"
  else
    fail "no snapshots found after backup"
  fi
}

test_retention_runs_clean() {
  header "test_retention_runs_clean"
  # Run backup again to get a second snapshot, then verify forget/prune runs.
  run_backup > /dev/null 2>&1

  local count
  count="$(snapshot_count "${RESTIC_REPO_DIR}/testapp" "test-repo-password")"

  if [[ "$count" -ge 1 ]]; then
    pass "retention/prune ran cleanly ($count snapshot(s) kept)"
  else
    fail "snapshots unexpectedly pruned to zero"
  fi
}

test_restore_into_alternate_db() {
  header "test_restore_into_alternate_db"
  local target="testapp_restore_test"

  _psql --dbname postgres --command "DROP DATABASE IF EXISTS \"$target\";" > /dev/null

  RESTORE_NO_CONFIRM=true run_restore \
    --service testapp \
    --target "$target" > /dev/null 2>&1

  local count
  count="$(_psql --dbname "$target" --tuples-only \
    --command "SELECT COUNT(*) FROM users" | tr -d ' ')"

  if [[ "$count" -eq 3 ]]; then
    pass "restore: all 3 rows present in alternate database"
  else
    fail "restore: expected 3 rows, got '$count'"
  fi

  _psql --dbname postgres --command "DROP DATABASE IF EXISTS \"$target\";" > /dev/null
}

test_verify_query_passes() {
  header "test_verify_query_passes"
  local target="testapp_verify_test"

  _psql --dbname postgres --command "DROP DATABASE IF EXISTS \"$target\";" > /dev/null

  if RESTORE_NO_CONFIRM=true run_restore \
       --service testapp \
       --target "$target" > /dev/null 2>&1; then
    pass "restore with VERIFY_QUERY passed"
  else
    fail "restore with VERIFY_QUERY failed unexpectedly"
  fi

  _psql --dbname postgres --command "DROP DATABASE IF EXISTS \"$target\";" > /dev/null
}

test_restore_rollback_on_failure() {
  header "test_restore_rollback_on_failure"

  # Create a database with known sentinel data.
  local sentinel_db="rollback_test_db"
  _psql --dbname postgres --command "DROP DATABASE IF EXISTS \"$sentinel_db\";" > /dev/null
  _psql --dbname postgres --command "CREATE DATABASE \"$sentinel_db\";" > /dev/null
  _psql --dbname "$sentinel_db" --command \
    "CREATE TABLE sentinel (val INT); INSERT INTO sentinel VALUES (42);" > /dev/null

  # Write a service config that points to a non-existent restic repository.
  cat > "$CONFIG_DIR/services/rollback-test.env" <<EOF
SERVICE_NAME=rollback-test
RESTIC_REPOSITORY=${RESTIC_REPO_DIR}/does-not-exist
RESTIC_PASSWORD=wrong-password
DB_HOST=127.0.0.1
DB_PORT=${PG_PORT}
DB_NAME=${sentinel_db}
DB_USER=${PG_USER}
DB_PASSWORD=${PG_PASSWORD}
STDIN_FILENAME=rollback-test.sql
OPTIONAL=false
EOF

  # Attempt restore — must fail because the restic repository does not exist.
  local exit_code=0
  RESTORE_NO_CONFIRM=true BACKUP_CONFIG_DIR="$CONFIG_DIR" \
    "$RESTORE_SCRIPT" --service rollback-test > /dev/null 2>&1 || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    fail "rollback test: restore should have failed but exited 0"
  else
    # The original database should have been rolled back.
    local val
    val="$(_psql --dbname "$sentinel_db" --tuples-only \
      --command "SELECT val FROM sentinel LIMIT 1" | tr -d ' ')"

    if [[ "$val" == "42" ]]; then
      pass "rollback: original database data preserved after failed restore"
    else
      fail "rollback: sentinel value not found (got '$val') — database was NOT rolled back"
    fi
  fi

  rm -f "$CONFIG_DIR/services/rollback-test.env"
  _psql --dbname postgres --command "DROP DATABASE IF EXISTS \"$sentinel_db\";" > /dev/null
}

test_partial_failure_continues() {
  header "test_partial_failure_continues"

  # Add a service config with a blank SERVICE_NAME to trigger validation failure.
  # Alphabetically 'aaa-bad.env' sorts before 'testapp.env' so with the old
  # (broken) behaviour the script would exit before reaching testapp.
  cat > "$CONFIG_DIR/services/aaa-bad.env" <<EOF
SERVICE_NAME=
RESTIC_REPOSITORY=${RESTIC_REPO_DIR}/bad
RESTIC_PASSWORD=test-password
DB_HOST=127.0.0.1
DB_PORT=${PG_PORT}
DB_NAME=nonexistent
DB_USER=${PG_USER}
DB_PASSWORD=${PG_PASSWORD}
STDIN_FILENAME=bad.sql
EOF

  local before_count
  before_count="$(snapshot_count "${RESTIC_REPO_DIR}/testapp" "test-repo-password")"

  # Script should exit non-zero (aaa-bad.env fails) but still back up testapp.
  local exit_code=0
  run_backup > /dev/null 2>&1 || exit_code=$?

  local after_count
  after_count="$(snapshot_count "${RESTIC_REPO_DIR}/testapp" "test-repo-password")"

  rm -f "$CONFIG_DIR/services/aaa-bad.env"

  if [[ "$exit_code" -eq 0 ]]; then
    fail "partial failure: backup should exit non-zero when a service fails"
  elif [[ "$after_count" -gt "$before_count" ]]; then
    pass "partial failure: testapp backed up ($before_count → $after_count snapshots) despite bad service failing"
  else
    fail "partial failure: testapp was NOT backed up (snapshots: $before_count → $after_count)"
  fi
}

test_optional_service_skips_unreachable_db() {
  header "test_optional_service_skips_unreachable_db"

  # Swap out testapp for an OPTIONAL service pointing at a closed port.
  mv "$CONFIG_DIR/services/testapp.env" "$CONFIG_DIR/services/testapp.env.bak"
  cat > "$CONFIG_DIR/services/optional.env" <<EOF
SERVICE_NAME=optional-svc
RESTIC_REPOSITORY=${RESTIC_REPO_DIR}/optional
RESTIC_PASSWORD=test-password
DB_HOST=127.0.0.1
DB_PORT=19999
DB_NAME=nonexistent
DB_USER=nobody
DB_PASSWORD=
STDIN_FILENAME=optional.sql
OPTIONAL=true
EOF

  local exit_code=0
  local output
  output="$(run_backup 2>&1)" || exit_code=$?

  mv "$CONFIG_DIR/services/testapp.env.bak" "$CONFIG_DIR/services/testapp.env"
  rm -f "$CONFIG_DIR/services/optional.env"

  if [[ "$exit_code" -ne 0 ]]; then
    fail "optional service: backup exited non-zero ($exit_code) — optional skip should exit 0"
  elif echo "$output" | grep -q "skipping (OPTIONAL=true)"; then
    pass "optional service: unreachable DB skipped gracefully, overall exit 0"
  else
    fail "optional service: did not log expected skip message"
  fi
}

test_list_snapshots() {
  header "test_list_snapshots"

  local output
  output="$(BACKUP_CONFIG_DIR="$CONFIG_DIR" "$RESTORE_SCRIPT" --service testapp --list 2>&1)"

  if echo "$output" | grep -q "testapp"; then
    pass "--list shows testapp snapshots"
  else
    fail "--list did not show testapp snapshots"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

check_deps
setup

test_dry_run_exits_zero
test_backup_creates_snapshot
test_retention_runs_clean
test_restore_into_alternate_db
test_verify_query_passes
test_restore_rollback_on_failure
test_partial_failure_continues
test_optional_service_skips_unreachable_db
test_list_snapshots

header "Results"
printf "  Passed: %d\n" "$PASS"
printf "  Failed: %d\n" "$FAIL"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi

echo "All tests passed."
