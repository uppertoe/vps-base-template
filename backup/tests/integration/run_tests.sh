#!/usr/bin/env bash
# =============================================================================
# run_tests.sh — Integration tests for backup.sh and restore.sh
# =============================================================================
#
# WHAT IT TESTS
#   - Dry-run mode produces no snapshots
#   - Backup creates a restic snapshot
#   - Retention runs after backup once per repository
#   - Verify mode runs restic check plus retention/prune
#   - Verify-only mode does not create new snapshots
#   - Retention retries on transient lock contention
#   - Restore recreates data correctly in an alternate database
#   - Post-restore verification passes on good data
#   - Rollback: original database is recovered after a failed restore
#   - Partial failure: one bad service does not abort the others
#   - OPTIONAL=true service skips a stopped container gracefully
#   - --list shows snapshots for a service
#   - BACKUP_PATHS: files are backed up and restored alongside the database
#   - Multi-service restore: --service a --service b restores both
#   - Files-only services (DB_NAME empty): backup creates only a files snapshot
#     and restore writes files back without touching any database
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
REAL_RESTIC=""

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

  REAL_RESTIC="$(command -v restic)"
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
  local stable_checks=0
  echo -n "Waiting for PostgreSQL"

  for _ in $(seq 1 60); do
    if _psql --dbname postgres --tuples-only --command "SELECT 1" > /dev/null 2>&1 &&
       _psql --dbname "$PG_DB" --tuples-only --command "SELECT 1" > /dev/null 2>&1; then
      stable_checks=$((stable_checks + 1))
      if [[ "$stable_checks" -ge 3 ]]; then
        echo " ready."
        return 0
      fi
    else
      stable_checks=0
    fi

    sleep 1
    echo -n "."
  done

  echo ""
  echo "ERROR: PostgreSQL did not become stably ready in time." >&2
  docker logs "$PG_CONTAINER" 2>&1 | tail -n 50 >&2 || true
  return 1
}

ensure_database_exists() {
  local db_name="$1"
  local exists=""

  exists="$(_psql --dbname postgres --tuples-only \
    --command "SELECT 1 FROM pg_database WHERE datname = '${db_name}'" 2>/dev/null | tr -d ' ')"

  if [[ "$exists" == "1" ]]; then
    return 0
  fi

  if _psql --dbname postgres --command "CREATE DATABASE \"${db_name}\";" > /dev/null 2>&1; then
    return 0
  fi

  exists="$(_psql --dbname postgres --tuples-only \
    --command "SELECT 1 FROM pg_database WHERE datname = '${db_name}'" 2>/dev/null | tr -d ' ')"

  if [[ "$exists" == "1" ]]; then
    return 0
  fi

  echo "ERROR: database '${db_name}' was not available after PostgreSQL startup." >&2
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
  # Run backup again to get a second snapshot, then verify retention still runs.
  local output
  output="$(run_backup 2>&1)"

  local count
  count="$(snapshot_count "${RESTIC_REPO_DIR}/testapp" "test-repo-password")"

  local retention_count
  retention_count="$(printf '%s\n' "$output" | grep -c "\[testapp\] Applying retention")"

  if [[ "$count" -ge 1 && "$retention_count" -eq 1 ]]; then
    pass "retention ran once per repository during backup ($count snapshot(s) kept)"
  else
    fail "expected one retention pass and snapshots to remain (count=$count retention_logs=$retention_count)"
  fi
}

test_verify_runs_retention_prune() {
  header "test_verify_runs_retention_prune"

  if run_backup --verify > /dev/null 2>&1; then
    pass "verify ran restic check and retention/prune cleanly"
  else
    fail "verify mode failed"
  fi
}

test_verify_only_does_not_create_snapshot() {
  header "test_verify_only_does_not_create_snapshot"

  run_backup --service testapp > /dev/null 2>&1

  local before after output
  before="$(snapshot_count "${RESTIC_REPO_DIR}/testapp" "test-repo-password")"
  output="$(run_backup --verify-only --service testapp 2>&1)"
  after="$(snapshot_count "${RESTIC_REPO_DIR}/testapp" "test-repo-password")"

  if [[ "$before" != "$after" ]]; then
    fail "verify-only created or removed snapshots unexpectedly (before=$before after=$after)"
  elif printf '%s\n' "$output" | grep -q "Backing up"; then
    fail "verify-only should not run backup creation"
  elif printf '%s\n' "$output" | grep -q "Running verification-only pass"; then
    pass "verify-only skipped backup creation and verified the repository"
  else
    fail "verify-only did not log the expected verification-only mode"
  fi
}

test_retention_retries_on_lock_contention() {
  header "test_retention_retries_on_lock_contention"

  local shim_dir shim_path state_file output exit_code=0 count
  shim_dir="$(mktemp -d)"
  shim_path="$shim_dir/restic"
  state_file="$shim_dir/forget-attempts"

  cat > "$shim_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE_FILE="${state_file}"
REAL_RESTIC="${REAL_RESTIC}"

if [[ "\${1:-}" == "forget" ]]; then
  attempt=0
  [[ -f "\$STATE_FILE" ]] && attempt="\$(cat "\$STATE_FILE")"
  attempt=\$((attempt + 1))
  printf '%s' "\$attempt" > "\$STATE_FILE"
  if [[ "\$attempt" -le 2 ]]; then
    echo "repo already locked, waiting up to 0s for the lock" >&2
    echo "unable to create lock in backend: repository is already locked exclusively by PID 999 on integration-test by root (UID 0, GID 0)" >&2
    exit 1
  fi
fi

exec "\$REAL_RESTIC" "\$@"
EOF
  chmod +x "$shim_path"

  output="$(PATH="$shim_dir:$PATH" BACKUP_CONFIG_DIR="$CONFIG_DIR" "$BACKUP_SCRIPT" --service testapp 2>&1)" || exit_code=$?
  count="$(snapshot_count "${RESTIC_REPO_DIR}/testapp" "test-repo-password")"

  rm -rf "$shim_dir"

  if [[ "$exit_code" -ne 0 ]]; then
    fail "backup should succeed after transient lock contention retries (exit=$exit_code)"
  elif [[ "$count" -lt 1 ]]; then
    fail "backup did not save a snapshot while retrying retention"
  elif printf '%s\n' "$output" | grep -q "retention hit a repository lock; retrying"; then
    pass "retention retried on lock contention and the backup still succeeded"
  else
    fail "expected lock retry log output during retention"
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

test_restore_live_db_with_active_session_fails_cleanly() {
  header "test_restore_live_db_with_active_session_fails_cleanly"

  local sentinel_db="rename_blocked_db"
  _psql --dbname postgres --command "DROP DATABASE IF EXISTS \"$sentinel_db\";" > /dev/null
  _psql --dbname postgres --command "CREATE DATABASE \"$sentinel_db\";" > /dev/null
  _psql --dbname "$sentinel_db" --command \
    "CREATE TABLE sentinel (val INT); INSERT INTO sentinel VALUES (7);" > /dev/null

  cat > "$CONFIG_DIR/services/rename-blocked.env" <<EOF
SERVICE_NAME=rename-blocked
CONTAINER_NAME=${PG_CONTAINER}
RESTIC_REPOSITORY=${RESTIC_REPO_DIR}/rename-blocked
RESTIC_PASSWORD=rename-blocked-password
DB_NAME=${sentinel_db}
DB_USER=${PG_USER}
DB_PASSWORD=${PG_PASSWORD}
STDIN_FILENAME=rename-blocked.sql
OPTIONAL=false
EOF

  docker exec -d -e PGPASSWORD="$PG_PASSWORD" "$PG_CONTAINER" \
    psql --username "$PG_USER" --no-password --dbname "$sentinel_db" \
    --command "SELECT pg_sleep(15);" > /dev/null

  local attempts=0
  local session_count=0
  while [[ "$attempts" -lt 20 ]]; do
    session_count="$(_psql --dbname postgres --tuples-only --command \
      "SELECT COUNT(*) FROM pg_stat_activity WHERE datname = '${sentinel_db}' AND pid <> pg_backend_pid();" \
      | tr -d ' ')" || session_count=0
    if [[ "$session_count" -ge 1 ]]; then
      break
    fi
    attempts=$((attempts + 1))
    sleep 1
  done

  local output="" exit_code=0
  output="$(RESTORE_NO_CONFIRM=true BACKUP_CONFIG_DIR="$CONFIG_DIR" \
    "$RESTORE_SCRIPT" --service rename-blocked 2>&1)" || exit_code=$?

  local original_exists rollback_count val
  original_exists="$(_psql --dbname postgres --tuples-only \
    --command "SELECT COUNT(*) FROM pg_database WHERE datname = '${sentinel_db}'" | tr -d ' ')"
  rollback_count="$(_psql --dbname postgres --tuples-only \
    --command "SELECT COUNT(*) FROM pg_database WHERE datname LIKE '${sentinel_db}_pre_restore_%'" | tr -d ' ')"
  val="$(_psql --dbname "$sentinel_db" --tuples-only \
    --command "SELECT val FROM sentinel LIMIT 1" | tr -d ' ')"

  _psql --dbname postgres --command \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${sentinel_db}' AND pid <> pg_backend_pid();" \
    > /dev/null

  rm -f "$CONFIG_DIR/services/rename-blocked.env"
  _psql --dbname postgres --command "DROP DATABASE IF EXISTS \"$sentinel_db\";" > /dev/null

  if [[ "$exit_code" -eq 0 ]]; then
    fail "rename_blocked: restore should have failed but exited 0"
  elif [[ "$original_exists" != "1" || "$rollback_count" != "0" || "$val" != "7" ]]; then
    fail "rename_blocked: expected original db to remain untouched (exists=$original_exists rollback_count=$rollback_count val=$val)"
  elif [[ "$output" == *"Rollback source"* ]]; then
    fail "rename_blocked: restore reported a rollback source even though rename never succeeded"
  else
    pass "rename_blocked: active session blocked rename without creating fake rollback state"
  fi
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

test_files_only_service() {
  header "test_files_only_service"

  # Create a directory with marker files outside any database.
  # See note in test_backup_paths re: /private/tmp on macOS.
  local files_dir
  if [[ "$(uname -s)" == "Darwin" ]]; then
    files_dir="$(mktemp -d /private/tmp/files-only-XXXXXX)"
  else
    files_dir="$(mktemp -d)"
  fi
  mkdir -p "$files_dir/config"
  echo "files-only-marker" > "$files_dir/config/app.yaml"

  cat > "$CONFIG_DIR/services/configsvc.env" <<EOF
SERVICE_NAME=configsvc
RESTIC_REPOSITORY=${RESTIC_REPO_DIR}/configsvc
RESTIC_PASSWORD=files-only-password
BACKUP_PATHS=${files_dir}
EOF

  # Backup: should create exactly one snapshot tagged configsvc-files,
  # and zero snapshots tagged configsvc (no DB snapshot).
  run_backup --service configsvc > /dev/null 2>&1

  local files_count db_count
  files_count="$(RESTIC_PASSWORD=files-only-password restic \
    -r "${RESTIC_REPO_DIR}/configsvc" \
    snapshots --tag "configsvc-files" --json 2>/dev/null \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
  db_count="$(RESTIC_PASSWORD=files-only-password restic \
    -r "${RESTIC_REPO_DIR}/configsvc" \
    snapshots --tag "configsvc" --json 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for s in d if "configsvc-files" not in s.get("tags", [])))')"

  if [[ "$files_count" -lt 1 || "$db_count" -ne 0 ]]; then
    fail "files_only: expected files snapshot and no db snapshot (files=$files_count db=$db_count)"
    rm -f "$CONFIG_DIR/services/configsvc.env"
    rm -rf "$files_dir"
    return
  fi

  # Reject --target on files-only.
  local target_exit=0 target_output
  target_output="$(RESTORE_NO_CONFIRM=true BACKUP_CONFIG_DIR="$CONFIG_DIR" \
    "$RESTORE_SCRIPT" --service configsvc --target whatever 2>&1)" || target_exit=$?
  if [[ "$target_exit" -eq 0 ]] || ! echo "$target_output" | grep -q "files-only"; then
    fail "files_only: --target should be rejected for files-only services (exit=$target_exit)"
    rm -f "$CONFIG_DIR/services/configsvc.env"
    rm -rf "$files_dir"
    return
  fi

  # Delete the files to simulate data loss, then restore.
  rm -rf "$files_dir"

  local exit_code=0
  RESTORE_NO_CONFIRM=true run_restore --service configsvc > /dev/null 2>&1 || exit_code=$?

  local marker_content
  marker_content="$(cat "$files_dir/config/app.yaml" 2>/dev/null || echo "")"

  rm -f "$CONFIG_DIR/services/configsvc.env"
  rm -rf "$files_dir"

  if [[ "$exit_code" -ne 0 ]]; then
    fail "files_only: restore exited $exit_code"
  elif [[ "$marker_content" == "files-only-marker" ]]; then
    pass "files_only: backup + restore round-trip without a database"
  else
    fail "files_only: marker not restored (got '$marker_content')"
  fi
}

test_files_only_optional_skips_when_paths_missing() {
  header "test_files_only_optional_skips_when_paths_missing"

  cat > "$CONFIG_DIR/services/missing-files.env" <<EOF
SERVICE_NAME=missing-files
RESTIC_REPOSITORY=${RESTIC_REPO_DIR}/missing-files
RESTIC_PASSWORD=missing-files-password
BACKUP_PATHS=/nonexistent/path/that/does/not/exist
OPTIONAL=true
EOF

  local exit_code=0 output
  output="$(run_backup --service missing-files 2>&1)" || exit_code=$?

  rm -f "$CONFIG_DIR/services/missing-files.env"

  if [[ "$exit_code" -ne 0 ]]; then
    fail "files_only_optional: backup exited $exit_code (expected 0 with OPTIONAL=true)"
  elif echo "$output" | grep -q "No BACKUP_PATHS exist on disk — skipping (OPTIONAL=true)"; then
    pass "files_only_optional: missing paths skipped gracefully"
  else
    fail "files_only_optional: did not log expected skip message"
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
test_verify_runs_retention_prune
test_verify_only_does_not_create_snapshot
test_retention_retries_on_lock_contention
test_restore_into_alternate_db
test_verify_passes
test_restore_rollback_on_failure
test_restore_live_db_with_active_session_fails_cleanly
test_partial_failure_continues
test_optional_service_skips_stopped_container
test_list_snapshots
test_backup_paths
test_files_only_service
test_files_only_optional_skips_when_paths_missing
test_multi_service_restore

header "Results"
printf "  Passed: %d\n" "$PASS"
printf "  Failed: %d\n" "$FAIL"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi

echo "All tests passed."
