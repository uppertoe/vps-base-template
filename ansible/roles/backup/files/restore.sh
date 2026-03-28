#!/usr/bin/env bash
# =============================================================================
# restore.sh — Restore one or more services from Restic snapshots.
# =============================================================================
#
# USAGE
#   restore.sh [--service NAME]... [OPTIONS]
#
#   --service NAME   Service to restore. Can be repeated. Omit to restore ALL
#                    services (disaster-recovery mode).
#   --snapshot ID    Restic snapshot ID for the database restore (default: latest).
#                    Only valid when restoring a single service.
#   --target DB      Restore the database into this name instead of the live
#                    database. Safe for testing without touching production.
#                    Only valid when restoring a single service.
#   --list           List available snapshots for a service and exit.
#                    Requires exactly one --service.
#   --dry-run        Print commands without executing.
#
# CONFIGURATION
#   Global config:   $BACKUP_CONFIG_DIR/config.env     (default: /etc/restic/config.env)
#   Per-service:     $BACKUP_CONFIG_DIR/services/NAME.env
#
# SAFETY
#   When restoring to the live database, the script prints a warning and
#   requires interactive confirmation unless RESTORE_NO_CONFIRM=true is set.
#
# FILE PATHS
#   If a service config sets BACKUP_PATHS, the most recent file snapshot
#   (tagged SERVICE_NAME-files) is restored to / after the database restore.
#   --snapshot does not apply to file restores; always uses latest.
#
# EXAMPLES
#   # Restore one service (interactive confirmation for live DB)
#   restore.sh --service myapp
#
#   # Safe test restore into an alternate database
#   restore.sh --service myapp --target myapp_restore_test
#
#   # Restore from a specific snapshot
#   restore.sh --service myapp --snapshot abc1234
#
#   # Restore two services
#   restore.sh --service myapp --service planka
#
#   # Restore everything (disaster recovery)
#   restore.sh
#
#   # List available snapshots
#   restore.sh --service myapp --list
# =============================================================================

set -eEuo pipefail  # -E: ERR trap inherited by functions (required for rollback)

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

SERVICE_NAMES=()
SNAPSHOT="latest"
TARGET_DB_ARG=""
LIST_ONLY=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service)  [[ -n "${2:-}" ]] || { echo "--service requires a NAME argument" >&2; exit 1; }
                SERVICE_NAMES+=("$2"); shift 2 ;;
    --snapshot) SNAPSHOT="$2";     shift 2 ;;
    --target)   TARGET_DB_ARG="$2"; shift 2 ;;
    --list)     LIST_ONLY=true;    shift ;;
    --dry-run)  DRY_RUN=true;      shift ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--service NAME]... [--snapshot ID] [--target DB] [--list] [--dry-run]" >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

CONFIG_DIR="${BACKUP_CONFIG_DIR:-/etc/restic}"
GLOBAL_CONFIG="$CONFIG_DIR/config.env"
SERVICES_DIR="$CONFIG_DIR/services"

if [[ -f "$GLOBAL_CONFIG" ]]; then
  # shellcheck source=/dev/null
  source "$GLOBAL_CONFIG"
fi

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

resolve_container_name() {
  local requested="$1"

  if docker inspect "$requested" >/dev/null 2>&1; then
    echo "$requested"
    return 0
  fi

  local -a matches=()
  local name=""
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    case "$name" in
      "$requested"|"$requested"-*|*"-$requested"|*"-$requested-"*)
        matches+=("$name")
        ;;
    esac
  done < <(docker ps -a --format '{{.Names}}')

  if [[ ${#matches[@]} -eq 1 ]]; then
    echo "${matches[0]}"
    return 0
  fi

  if [[ ${#matches[@]} -gt 1 ]]; then
    warn "[$requested] Multiple container matches found: ${matches[*]}"
    return 1
  fi

  warn "[$requested] No matching Docker container found."
  return 1
}

# ---------------------------------------------------------------------------
# Per-service state — updated by restore_service(), read by _rollback_db.
# Not declared local so the ERR trap can access them from any call depth.
# ---------------------------------------------------------------------------

ROLLBACK_DB=""
TARGET_DB=""
SERVICE_NAME=""
CONTAINER_NAME=""
DB_NAME=""
DB_USER=""
DB_PASSWORD=""
RESTIC_REPOSITORY=""
RESTIC_PASSWORD=""
STDIN_FILENAME=""
BACKUP_PATHS=""

# ---------------------------------------------------------------------------
# PostgreSQL helpers (via docker exec)
# ---------------------------------------------------------------------------

_psql_admin() {
  # Admin operations (CREATE/DROP/ALTER DATABASE). No stdin needed.
  docker exec -e PGPASSWORD="${DB_PASSWORD:-}" "$CONTAINER_NAME" \
    psql --username "$DB_USER" --no-password "$@" < /dev/null
}

_psql_app() {
  # App user queries. Uses -i so stdin can be piped (e.g. SQL dump from restic).
  docker exec -e PGPASSWORD="${DB_PASSWORD:-}" -i "$CONTAINER_NAME" \
    psql --username "$DB_USER" --no-password "$@"
}

db_exists() {
  local db="$1"
  _psql_admin --tuples-only \
    --command "SELECT 1 FROM pg_database WHERE datname='$db'" \
    postgres 2>/dev/null | grep -q 1
}

# ---------------------------------------------------------------------------
# Rollback trap
# ---------------------------------------------------------------------------
# If restore fails after the original database was renamed, this trap drops
# the partial restore and renames the original back.
# Uses script-level globals set by restore_service().

_rollback_db() {
  trap - ERR
  [[ -n "$ROLLBACK_DB" ]] || return 0

  warn "Restore failed — rolling back '$TARGET_DB' to pre-restore state..."

  _psql_admin postgres \
    --command "DROP DATABASE IF EXISTS \"$TARGET_DB\";" 2>/dev/null || true

  if db_exists "$ROLLBACK_DB"; then
    _psql_admin postgres \
      --command "ALTER DATABASE \"$ROLLBACK_DB\" RENAME TO \"$TARGET_DB\";"
    warn "Rollback complete — '$TARGET_DB' is back to its pre-restore state."
  else
    warn "Rollback source '$ROLLBACK_DB' not found — manual recovery required."
    warn "  Recover with: ALTER DATABASE \"$ROLLBACK_DB\" RENAME TO \"$TARGET_DB\";"
  fi
}

trap '_rollback_db' ERR

# ---------------------------------------------------------------------------
# Confirm destructive operations
# ---------------------------------------------------------------------------

confirm_destructive() {
  local target="$1" real="$2"
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
# Per-service restore
# ---------------------------------------------------------------------------

restore_service() {
  local env_file="$1"
  local resolved_container_name=""

  # Reset per-service state. Not declared local — _rollback_db must see these.
  ROLLBACK_DB=""
  SERVICE_NAME="" CONTAINER_NAME="" DB_NAME="" DB_USER="" DB_PASSWORD=""
  RESTIC_REPOSITORY="" RESTIC_PASSWORD="" STDIN_FILENAME="" BACKUP_PATHS=""

  [[ -f "$env_file" ]] || { warn "Service config not found: $env_file"; return 1; }

  # shellcheck source=/dev/null
  source "$env_file"

  # Validate required variables.
  local var missing=0
  for var in SERVICE_NAME CONTAINER_NAME DB_NAME DB_USER RESTIC_REPOSITORY RESTIC_PASSWORD STDIN_FILENAME; do
    if [[ -z "${!var:-}" ]]; then
      warn "[$env_file] \$$var is not set — skipping."
      missing=1
    fi
  done
  [[ $missing -eq 0 ]] || return 1

  if ! resolved_container_name="$(resolve_container_name "$CONTAINER_NAME")"; then
    warn "[$SERVICE_NAME] Container '$CONTAINER_NAME' could not be resolved."
    return 1
  fi
  CONTAINER_NAME="$resolved_container_name"

  export RESTIC_REPOSITORY RESTIC_PASSWORD

  # TARGET_DB: honour --target for single-service runs, else use the real DB name.
  TARGET_DB="${TARGET_DB_ARG:-$DB_NAME}"

  info "================================================================="
  info "Restoring service: $SERVICE_NAME"
  info "  Container: $CONTAINER_NAME"
  info "  Snapshot:  $SNAPSHOT"
  info "  Target DB: $TARGET_DB"
  [[ -n "${BACKUP_PATHS:-}" ]] && info "  File paths: $BACKUP_PATHS"
  "$DRY_RUN" && info "  (dry-run mode — no changes will be made)"
  info "================================================================="

  confirm_destructive "$TARGET_DB" "$DB_NAME"

  if "$DRY_RUN"; then
    echo "DRY-RUN: restic dump $SNAPSHOT --tag $SERVICE_NAME /$STDIN_FILENAME | psql $TARGET_DB"
    [[ -n "${BACKUP_PATHS:-}" ]] && \
      echo "DRY-RUN: restic restore latest --tag ${SERVICE_NAME}-files --target /"
    return 0
  fi

  # Preserve the existing database for rollback.
  if db_exists "$TARGET_DB"; then
    ROLLBACK_DB="${TARGET_DB}_pre_restore_$(date -u +%Y%m%dT%H%M%SZ)"
    info "Preserving '$TARGET_DB' -> '$ROLLBACK_DB' for rollback safety..."
    _psql_admin postgres \
      --command "ALTER DATABASE \"$TARGET_DB\" RENAME TO \"$ROLLBACK_DB\";"
  fi

  info "Creating database '$TARGET_DB'..."
  _psql_admin postgres --command "CREATE DATABASE \"$TARGET_DB\";"

  # Restore the database from the restic snapshot.
  restic dump "$SNAPSHOT" --tag "$SERVICE_NAME" "/$STDIN_FILENAME" \
    | _psql_app --dbname "$TARGET_DB" > /dev/null

  # Verify the restore produced a non-empty database.
  info "Verifying restore..."
  local table_count
  table_count="$(_psql_app --dbname "$TARGET_DB" --tuples-only \
    --command "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public'" \
    | tr -d ' \n')"
  info "  Tables in restored database: $table_count"
  [[ "$table_count" -gt 0 ]] || \
    die "[$SERVICE_NAME] Restore verification failed — no tables found in '$TARGET_DB'."
  info "  Verification passed."

  # Restore file paths if configured.
  if [[ -n "${BACKUP_PATHS:-}" ]]; then
    info "[$SERVICE_NAME] Checking for file snapshots..."
    local file_snap_count
    file_snap_count="$(restic snapshots --tag "${SERVICE_NAME}-files" --json 2>/dev/null \
      | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"

    if [[ "$file_snap_count" -gt 0 ]]; then
      info "[$SERVICE_NAME] Restoring file paths (latest snapshot)..."
      restic restore latest --tag "${SERVICE_NAME}-files" --target /
      info "[$SERVICE_NAME] File paths restored."
    else
      warn "[$SERVICE_NAME] No file snapshots found — skipping file restore."
    fi
  fi

  # Clear rollback marker on success so the trap does nothing on exit.
  local _preserved="$ROLLBACK_DB"
  ROLLBACK_DB=""

  info "================================================================="
  info "Restore complete — $SERVICE_NAME -> $TARGET_DB."
  info "================================================================="

  if [[ -n "$_preserved" ]]; then
    echo ""
    echo "  Pre-restore database preserved as: '$_preserved'"
    echo "  Verify the restore, then drop it:"
    printf "    docker exec -e PGPASSWORD=... %s psql -U %s -d postgres -c 'DROP DATABASE \"%s\";'\n" \
      "$CONTAINER_NAME" "$DB_USER" "$_preserved"
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

main() {
  # Collect service env files.
  local service_files=()

  if [[ ${#SERVICE_NAMES[@]} -gt 0 ]]; then
    for name in "${SERVICE_NAMES[@]}"; do
      local f="$SERVICES_DIR/${name}.env"
      [[ -f "$f" ]] || die "Service config not found: $f"
      service_files+=("$f")
    done
  else
    for f in "$SERVICES_DIR"/*.env; do
      [[ -f "$f" ]] && service_files+=("$f")
    done
    [[ ${#service_files[@]} -gt 0 ]] || die "No service configs found in $SERVICES_DIR/"
  fi

  # Options that only make sense for a single service.
  if [[ ${#service_files[@]} -gt 1 ]]; then
    [[ -z "$TARGET_DB_ARG" ]] || \
      die "--target can only be used with a single --service"
    [[ "$SNAPSHOT" == "latest" ]] || \
      die "--snapshot can only be used with a single --service"
  fi

  # List mode — show snapshots for one service and exit.
  if "$LIST_ONLY"; then
    [[ ${#service_files[@]} -eq 1 ]] || die "--list requires exactly one --service"
    source "${service_files[0]}"
    export RESTIC_REPOSITORY RESTIC_PASSWORD
    info "Snapshots for service '$SERVICE_NAME' (repository: $RESTIC_REPOSITORY):"
    restic snapshots --tag "$SERVICE_NAME"
    exit 0
  fi

  if [[ ${#service_files[@]} -eq 1 ]]; then
    # Single service: direct call so the ERR trap and rollback work at this level.
    restore_service "${service_files[0]}"
  else
    # Multiple services: run each in a subshell. The ERR trap is inherited (-E)
    # so rollback fires correctly inside each subshell. Failures are accumulated.
    local failed_services=()
    for env_file in "${service_files[@]}"; do
      if ! ( restore_service "$env_file" ); then
        failed_services+=("$(basename "$env_file" .env)")
      fi
    done

    if [[ ${#failed_services[@]} -gt 0 ]]; then
      warn "================================================================="
      warn "The following services failed to restore:"
      for svc in "${failed_services[@]}"; do
        warn "  - $svc"
      done
      warn "================================================================="
      exit 1
    fi
  fi
}

main
