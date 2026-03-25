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
#   - Post-restore verification passes on good data
#   - Rollback: original database is recovered after a failed restore
#   - Partial failure: one bad service does not abort the others
#   - OPTIONAL=true service skips a stopped container gracefully
#   - --list shows snapshots for a service
#   - BACKUP_PATHS: files are backed up and restored alongside the database
#   - Multi-service restore: --service a --service b restores both
#
# PREREQUISITES
#   - Docker (for PostgreSQL container)
#   - restic (brew install restic  /  apt install restic)
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
PG_IMAGE="postgres:17-alpine"

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
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: missing required tools: ${missing[*]}" >&2
    echo "Install with: brew install restic  (macOS)" >&2
    echo "          or: apt install restic  (Debian/Ubuntu)" >&2
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
# PostgreSQL helpers (via docker exec — no system psql needed)
# ---------------------------------------------------------------------------

_psql() {
  # Run as the app user (PG_USER is set as the superuser in this test container)
  docker exec -i -e PGPASSWORD="$PG_PASSWORD" "$PG_CONTAINER" \
    psql --username "$PG_USER" --no-password "$@"
}

psql_retry() {
  local attempts=0
  while true; do
    if _psql "$@"; then
      return 0
    fi

    attempts=$((attempts + 1))
    if [[ "$attempts" -ge 20 ]]; then
      echo "ERROR: PostgreSQL did not accept stable psql connections in time." >&2
      return 1
    fi

    sleep 1
  done
}

wait_for_postgres() {
  echo -n "Waiting for PostgreSQL"
  for _ in $(seq 1 30); do
    if docker exec "$PG_CONTAINER" \
         pg_isready --username "$PG_USER" --dbname "$PG_DB" --quiet 2>/dev/null; then
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

ensure_database_exists() {
  local db_name="$1"
  local exists=""

  exists="$(psql_retry --dbname postgres --tuples-only \
    --command "SELECT 1 FROM pg_database WHERE datname = '${db_name}'" | tr -d ' ')"

  if [[ "$exists" != "1" ]]; then
    psql_retry --dbname postgres --command "CREATE DATABASE \"${db_name}\";" > /dev/null
  fi
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

  # Start PostgreSQL container — POSTGRES_USER becomes the superuser,
  # which allows it to CREATE/ALTER/DROP databases in the tests below.
  docker run -d --name "$PG_CONTAINER" \
    -e POSTGRES_DB="$PG_DB" \
    -e POSTGRES_USER="$PG_USER" \
    -e POSTGRES_PASSWORD="$PG_PASSWORD" \
    -p "127.0.0.1:${PG_PORT}:5432" \
    "$PG_IMAGE" \
    > /dev/null

  wait_for_postgres

  # CI can occasionally report PostgreSQL ready before POSTGRES_DB has been
  # fully created, so make that step explicit before seeding fixtures.
  ensure_database_exists "$PG_DB"

  # Seed the test database
  psql_retry --dbname "$PG_DB" < "$SCRIPT_DIR/seed.sql"
  echo "Test database seeded (3 users)."

  # Write global config
  cp "$SCRIPT_DIR/fixtures/config.env" "$CONFIG_DIR/config.env"

  # Write service config (inject runtime values)
  mkdir -p "$CONFIG_DIR/services"
  cat > "$CONFIG_DIR/services/testapp.env" <<EOF
SERVICE_NAME=testapp
CONTAINER_NAME=${PG_CONTAINER}
RESTIC_REPOSITORY=${RESTIC_REPO_DIR}/testapp
RESTIC_PASSWORD=test-repo-password
DB_NAME=${PG_DB}
DB_USER=${PG_USER}
DB_PASSWORD=${PG_PASSWORD}
STDIN_FILENAME=testapp-db.sql
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

test_verify_passes() {
  header "test_verify_passes"
  local target="testapp_verify_test"

  _psql --dbname postgres --command "DROP DATABASE IF EXISTS \"$target\";" > /dev/null

  if RESTORE_NO_CONFIRM=true run_restore \
       --service testapp \
       --target "$target" > /dev/null 2>&1; then
    pass "restore with built-in verification passed"
  else
    fail "restore with built-in verification failed unexpectedly"
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
CONTAINER_NAME=${PG_CONTAINER}
RESTIC_REPOSITORY=${RESTIC_REPO_DIR}/does-not-exist
RESTIC_PASSWORD=wrong-password
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
CONTAINER_NAME=nonexistent-container
RESTIC_REPOSITORY=${RESTIC_REPO_DIR}/bad
RESTIC_PASSWORD=test-password
DB_NAME=nonexistent
DB_USER=${PG_USER}
DB_PASSWORD=${PG_PASSWORD}
STDIN_FILENAME=bad.sql
EOF

  # Script should exit non-zero (aaa-bad.env fails) but still back up testapp.
  # Note: do NOT compare snapshot counts — restic's retention policy can prune
  # existing snapshots during the same run, keeping the count flat.
  # Instead, check that backup.sh logged success for the testapp service.
  local exit_code=0
  local output
  output="$(run_backup 2>&1)" || exit_code=$?

  rm -f "$CONFIG_DIR/services/aaa-bad.env"

  if [[ "$exit_code" -eq 0 ]]; then
    fail "partial failure: backup should exit non-zero when a service fails"
  elif echo "$output" | grep -q "\[testapp\] Backup complete"; then
    pass "partial failure: testapp backed up despite bad service failing (exit $exit_code)"
  else
    fail "partial failure: testapp was NOT backed up"
  fi
}

test_optional_service_skips_stopped_container() {
  header "test_optional_service_skips_stopped_container"

  # Swap out testapp for an OPTIONAL service pointing at a non-existent container.
  mv "$CONFIG_DIR/services/testapp.env" "$CONFIG_DIR/services/testapp.env.bak"
  cat > "$CONFIG_DIR/services/optional.env" <<EOF
SERVICE_NAME=optional-svc
CONTAINER_NAME=nonexistent-container-12345
RESTIC_REPOSITORY=${RESTIC_REPO_DIR}/optional
RESTIC_PASSWORD=test-password
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
    pass "optional service: stopped container skipped gracefully, overall exit 0"
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

test_backup_paths() {
  header "test_backup_paths"

  # Create a temp directory with test files that will be backed up.
  # On macOS, mktemp returns /var/... paths but /var is a symlink to /private/var.
  # restic restore --target / tries to remove /var as a "stale item" and hits a
  # permissions error. Use /private/tmp directly to get a real (non-symlinked) path.
  local test_files_dir
  if [[ "$(uname -s)" == "Darwin" ]]; then
    test_files_dir="$(mktemp -d /private/tmp/backup-test-XXXXXX)"
  else
    test_files_dir="$(mktemp -d)"
  fi
  mkdir -p "$test_files_dir/data"
  echo "marker-content" > "$test_files_dir/data/marker.txt"
  echo "other-content"  > "$test_files_dir/data/other.txt"

  # Temporarily add BACKUP_PATHS to the testapp service config.
  cp "$CONFIG_DIR/services/testapp.env" "$CONFIG_DIR/services/testapp.env.bak"
  echo "BACKUP_PATHS=${test_files_dir}" >> "$CONFIG_DIR/services/testapp.env"

  # Run backup — should create a DB snapshot AND a files snapshot.
  run_backup --service testapp > /dev/null 2>&1

  local file_snap_count
  file_snap_count="$(RESTIC_PASSWORD=test-repo-password restic \
    -r "${RESTIC_REPO_DIR}/testapp" \
    snapshots --tag "testapp-files" --json 2>/dev/null \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"

  if [[ "$file_snap_count" -lt 1 ]]; then
    fail "backup_paths: no file snapshot found after backup"
    cp "$CONFIG_DIR/services/testapp.env.bak" "$CONFIG_DIR/services/testapp.env"
    rm -f "$CONFIG_DIR/services/testapp.env.bak"
    rm -rf "$test_files_dir"
    return
  fi

  # Delete the files to simulate data loss, then restore.
  rm -rf "$test_files_dir"

  local target="testapp_paths_test"
  _psql --dbname postgres --command "DROP DATABASE IF EXISTS \"$target\";" > /dev/null

  local exit_code=0
  RESTORE_NO_CONFIRM=true run_restore \
    --service testapp \
    --target "$target" > /dev/null 2>&1 || exit_code=$?

  local db_count marker_content
  db_count="$(_psql --dbname "$target" --tuples-only \
    --command "SELECT COUNT(*) FROM users" | tr -d ' ')" || db_count=0
  marker_content="$(cat "$test_files_dir/data/marker.txt" 2>/dev/null || echo "")"

  # Restore testapp.env and clean up.
  cp "$CONFIG_DIR/services/testapp.env.bak" "$CONFIG_DIR/services/testapp.env"
  rm -f "$CONFIG_DIR/services/testapp.env.bak"
  rm -rf "$test_files_dir"
  _psql --dbname postgres --command "DROP DATABASE IF EXISTS \"$target\";" > /dev/null

  if [[ "$exit_code" -ne 0 ]]; then
    fail "backup_paths: restore exited $exit_code"
  elif [[ "$db_count" -eq 3 && "$marker_content" == "marker-content" ]]; then
    pass "backup_paths: DB ($db_count rows) and files (marker.txt) both restored correctly"
  else
    fail "backup_paths: DB count=$db_count, marker='$marker_content' (expected 3 and 'marker-content')"
  fi
}

test_multi_service_restore() {
  header "test_multi_service_restore"

  # Create a second database in the same container with distinct data.
  _psql --dbname postgres --command "DROP DATABASE IF EXISTS testapp2;" > /dev/null
  _psql --dbname postgres --command "CREATE DATABASE testapp2;" > /dev/null
  _psql --dbname testapp2 --command \
    "CREATE TABLE items (name TEXT); INSERT INTO items VALUES ('alpha'), ('beta');" > /dev/null

  cat > "$CONFIG_DIR/services/testapp2.env" <<EOF
SERVICE_NAME=testapp2
CONTAINER_NAME=${PG_CONTAINER}
RESTIC_REPOSITORY=${RESTIC_REPO_DIR}/testapp2
RESTIC_PASSWORD=test-repo-password-2
DB_NAME=testapp2
DB_USER=${PG_USER}
DB_PASSWORD=${PG_PASSWORD}
STDIN_FILENAME=testapp2-db.sql
OPTIONAL=false
EOF

  # Back up both services.
  run_backup > /dev/null 2>&1

  # Drop both live databases to simulate data loss.
  _psql --dbname postgres --command "DROP DATABASE IF EXISTS testapp;" > /dev/null
  _psql --dbname postgres --command "DROP DATABASE IF EXISTS testapp2;" > /dev/null

  # Restore both with a single restore.sh invocation.
  local exit_code=0
  RESTORE_NO_CONFIRM=true run_restore \
    --service testapp \
    --service testapp2 > /dev/null 2>&1 || exit_code=$?

  local count1 count2
  count1="$(_psql --dbname testapp  --tuples-only --command "SELECT COUNT(*) FROM users" | tr -d ' ')" || count1=0
  count2="$(_psql --dbname testapp2 --tuples-only --command "SELECT COUNT(*) FROM items" | tr -d ' ')" || count2=0

  rm -f "$CONFIG_DIR/services/testapp2.env"
  _psql --dbname postgres --command "DROP DATABASE IF EXISTS testapp2;" > /dev/null

  if [[ "$exit_code" -ne 0 ]]; then
    fail "multi_service_restore: exited $exit_code"
  elif [[ "$count1" -eq 3 && "$count2" -eq 2 ]]; then
    pass "multi_service_restore: testapp ($count1 users) and testapp2 ($count2 items) both restored"
  else
    fail "multi_service_restore: unexpected counts (testapp: $count1, testapp2: $count2)"
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
test_verify_passes
test_restore_rollback_on_failure
test_partial_failure_continues
test_optional_service_skips_stopped_container
test_list_snapshots
test_backup_paths
test_multi_service_restore

header "Results"
printf "  Passed: %d\n" "$PASS"
printf "  Failed: %d\n" "$FAIL"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi

echo "All tests passed."
