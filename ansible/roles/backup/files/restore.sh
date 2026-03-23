#!/usr/bin/env bash
# =============================================================================
# restore.sh — Restore a PostgreSQL database from a Restic snapshot.
# =============================================================================
#
# USAGE
#   restore.sh --service NAME [OPTIONS]
#
#   --service NAME   Which service to restore (required). Must match a file
#                    in $BACKUP_CONFIG_DIR/services/NAME.env.
#   --snapshot ID    Restic snapshot ID (default: latest).
#   --target DB      Target database name. Defaults to the real database name.
#                    Set to a different name (e.g. myapp_restore_test) to
#                    restore into a new database without touching production.
#                    The target database is created if it does not exist.
#   --list           List available snapshots for the named service and exit.
#   --dry-run        Print commands without executing.
#
# CONFIGURATION
#   Global config:   $BACKUP_CONFIG_DIR/config.env     (default: /etc/restic/config.env)
#   Per-service:     $BACKUP_CONFIG_DIR/services/NAME.env
#
# SAFETY
#   When --target matches the real database name, the script prints a prominent
#   warning and requires interactive confirmation unless RESTORE_NO_CONFIRM=true
#   is set. Use RESTORE_NO_CONFIRM=true only in automated testing pipelines.
#
# EXAMPLES
#   # List available snapshots for a service
#   restore.sh --service myapp --list
#
#   # Test restore into a temporary database (safe — does not touch production)
#   restore.sh --service myapp --target myapp_restore_test
#
#   # Restore from a specific snapshot
#   restore.sh --service myapp --snapshot abc1234 --target myapp_restore_test
#
#   # Production restore (prompts for confirmation)
#   restore.sh --service myapp --snapshot abc1234
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

SERVICE_NAME=""
SNAPSHOT="latest"
TARGET_DB=""
LIST_ONLY=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service)  [[ -n "${2:-}" ]] || { echo "--service requires a NAME argument" >&2; exit 1; }
                SERVICE_NAME="$2"; shift 2 ;;
    --snapshot) SNAPSHOT="$2";  shift 2 ;;
    --target)   TARGET_DB="$2"; shift 2 ;;
    --list)     LIST_ONLY=true; shift ;;
    --dry-run)  DRY_RUN=true;   shift ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 --service NAME [--snapshot ID] [--target DB] [--list] [--dry-run]" >&2
      exit 1
      ;;
  esac
done

[[ -n "$SERVICE_NAME" ]] || { echo "Error: --service NAME is required." >&2; exit 1; }

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

CONFIG_DIR="${BACKUP_CONFIG_DIR:-/etc/restic}"
GLOBAL_CONFIG="$CONFIG_DIR/config.env"
SERVICE_ENV="$CONFIG_DIR/services/${SERVICE_NAME}.env"

[[ -f "$SERVICE_ENV" ]] || {
  echo "Error: service config not found: $SERVICE_ENV" >&2
  exit 1
}

# Source global config (AWS creds etc.) then service config.
if [[ -f "$GLOBAL_CONFIG" ]]; then
  # shellcheck source=/dev/null
  source "$GLOBAL_CONFIG"
fi

# Load per-service variables.
# shellcheck source=/dev/null
source "$SERVICE_ENV"

# Export restic credentials for all restic commands.
export RESTIC_REPOSITORY RESTIC_PASSWORD

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log()  { echo "[$(date -u +%H:%M:%SZ)] $*"; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*"; }
die()  { log "ERROR $*" >&2; exit 1; }

run() {
  if "$DRY_RUN"; then
    echo "DRY-RUN: $*"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# Validate required service variables
# ---------------------------------------------------------------------------

require_var() {
  local var="$1"
  [[ -n "${!var:-}" ]] || die "Required variable \$$var is not set in $SERVICE_ENV."
}

require_var RESTIC_REPOSITORY
require_var RESTIC_PASSWORD
require_var DB_HOST
require_var DB_NAME
require_var DB_USER
require_var STDIN_FILENAME

# ---------------------------------------------------------------------------
# Resolve target database
# ---------------------------------------------------------------------------

TARGET_DB="${TARGET_DB:-$DB_NAME}"

# Tracks the pre-restore database name created for rollback; set inside do_restore.
ROLLBACK_DB=""
RESTORE_TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"

# ---------------------------------------------------------------------------
# Confirm destructive operations
# ---------------------------------------------------------------------------

confirm_destructive() {
  local target="$1" real="$2"

  # Restoring to a different name — safe, no confirmation needed.
  [[ "$target" == "$real" ]] || return 0

  if [[ "${RESTORE_NO_CONFIRM:-false}" == "true" ]]; then
    warn "RESTORE_NO_CONFIRM=true — skipping confirmation prompt."
    return 0
  fi

  echo ""
  echo "  ╔══════════════════════════════════════════════════════════╗"
  echo "  ║              ⚠  DESTRUCTIVE OPERATION  ⚠                ║"
  echo "  ║                                                          ║"
  printf "  ║  You are about to overwrite the database '%s'.\n" "$target"
  echo "  ║  ALL EXISTING DATA WILL BE REPLACED.                     ║"
  echo "  ║                                                          ║"
  printf "  ║  Snapshot: %s\n" "$SNAPSHOT"
  echo "  ║                                                          ║"
  echo "  ║  To restore safely without this prompt, use --target     ║"
  echo "  ║  with a different database name, verify the data, then   ║"
  echo "  ║  swap databases manually.                                ║"
  echo "  ╚══════════════════════════════════════════════════════════╝"
  echo ""
  read -r -p "  Type the database name to confirm: " confirmation

  [[ "$confirmation" == "$target" ]] || die "Confirmation did not match — aborting."
}

# ---------------------------------------------------------------------------
# PostgreSQL helpers
# ---------------------------------------------------------------------------

_psql() {
  PGPASSWORD="${DB_PASSWORD:-}" psql \
    --host     "$DB_HOST" \
    --port     "${DB_PORT:-5432}" \
    --username "$DB_USER" \
    --no-password \
    "$@"
}

db_exists() {
  local db="$1"
  PGPASSWORD="${DB_PASSWORD:-}" psql \
    --host "$DB_HOST" --port "${DB_PORT:-5432}" \
    --username "$DB_USER" --no-password \
    --tuples-only \
    --command "SELECT 1 FROM pg_database WHERE datname='$db'" \
    postgres 2>/dev/null | grep -q 1
}

# ---------------------------------------------------------------------------
# Rollback trap
# ---------------------------------------------------------------------------
# If restore fails after we have renamed the original database, this trap
# drops the partial restore and renames the original back.

_rollback_db() {
  trap - ERR  # prevent recursive invocation on rollback failure
  [[ -n "$ROLLBACK_DB" ]] || return 0

  warn "Restore failed — rolling back to pre-restore state…"

  # Drop the partial (possibly empty) target database.
  _psql --dbname postgres \
    --command "DROP DATABASE IF EXISTS \"$TARGET_DB\";" 2>/dev/null || true

  # Rename the preserved pre-restore database back.
  if db_exists "$ROLLBACK_DB"; then
    _psql --dbname postgres \
      --command "ALTER DATABASE \"$ROLLBACK_DB\" RENAME TO \"$TARGET_DB\";"
    warn "Rollback complete — '$TARGET_DB' is back to its pre-restore state."
  else
    warn "Rollback source '$ROLLBACK_DB' not found — manual recovery required."
    warn "  Recover with: ALTER DATABASE \"$ROLLBACK_DB\" RENAME TO \"$TARGET_DB\";"
  fi
}

trap '_rollback_db' ERR

# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------

do_restore() {
  info "================================================================="
  info "Restore started"
  info "  Service:   $SERVICE_NAME"
  info "  Snapshot:  $SNAPSHOT"
  info "  Source:    /$STDIN_FILENAME"
  info "  Target:    $TARGET_DB on $DB_HOST"
  "$DRY_RUN" && info "  (dry-run mode — no changes will be made)"
  info "================================================================="

  confirm_destructive "$TARGET_DB" "$DB_NAME"

  if "$DRY_RUN"; then
    echo "DRY-RUN: restic dump $SNAPSHOT --tag $SERVICE_NAME /$STDIN_FILENAME | psql $TARGET_DB"
    return 0
  fi

  # Preserve the existing database under a timestamped name so we can roll
  # back if the restore fails. On success the caller can drop it manually.
  if db_exists "$TARGET_DB"; then
    ROLLBACK_DB="${TARGET_DB}_pre_restore_${RESTORE_TIMESTAMP}"
    info "Preserving '$TARGET_DB' → '$ROLLBACK_DB' for rollback safety…"
    _psql --dbname postgres \
      --command "ALTER DATABASE \"$TARGET_DB\" RENAME TO \"$ROLLBACK_DB\";"
  fi

  info "Creating database '$TARGET_DB'…"
  _psql --dbname postgres --command "CREATE DATABASE \"$TARGET_DB\";"

  # Dump the snapshot directly into psql.
  # The leading slash is required — restic stores stdin files as /filename.
  # Discard psql stdout (sequence setval rows); surface only stderr (errors).
  restic dump "$SNAPSHOT" --tag "$SERVICE_NAME" "/$STDIN_FILENAME" \
    | _psql --dbname "$TARGET_DB" > /dev/null

  # Optional post-restore verification query.
  if [[ -n "${VERIFY_QUERY:-}" ]]; then
    info "Verifying restore…"
    local count
    count="$(_psql --dbname "$TARGET_DB" --tuples-only \
               --command "$VERIFY_QUERY" | tr -d ' \n')"
    info "  Verification result: $count"
    [[ "$count" -gt 0 ]] || die "Restore verification failed — query returned 0 or empty."
    info "  Verification passed."
  fi

  info "================================================================="
  info "Restore complete — '$SERVICE_NAME' → '$TARGET_DB'."
  info "================================================================="

  if [[ -n "$ROLLBACK_DB" ]]; then
    echo ""
    echo "  Pre-restore snapshot preserved as: '$ROLLBACK_DB'"
    echo "  Verify the restore, then drop it:"
    printf "    psql -c 'DROP DATABASE \"%s\";'\n" "$ROLLBACK_DB"
    echo ""
  fi

  if [[ "$TARGET_DB" != "$DB_NAME" ]]; then
    echo ""
    echo "  Restored into '$TARGET_DB' (not the live database '$DB_NAME')."
    echo "  To promote to live, stop the app then run:"
    echo ""
    echo "    DROP DATABASE \"$DB_NAME\";"
    echo "    ALTER DATABASE \"$TARGET_DB\" RENAME TO \"$DB_NAME\";"
    echo ""
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if "$LIST_ONLY"; then
  info "Snapshots for service '$SERVICE_NAME' (repository: $RESTIC_REPOSITORY):"
  restic snapshots --tag "$SERVICE_NAME"
  exit 0
fi

do_restore
