#!/usr/bin/env bash
# =============================================================================
# backup.sh — Back up PostgreSQL databases to Restic repositories.
# =============================================================================
#
# USAGE
#   backup.sh [--dry-run] [--verify] [--verify-only] [--service NAME]
#
#   --dry-run         Print every command that would run; make no changes.
#   --verify          After backing up, run `restic check`, apply retention with
#                     prune, and list recent snapshots.
#   --verify-only     Skip backup creation entirely and run verification mode
#                     only (restic check + retention/prune + recent snapshots).
#   --service NAME    Back up only the named service (default: all services).
#
# CONFIGURATION
#   Global config:   $BACKUP_CONFIG_DIR/config.env     (default: /etc/restic/config.env)
#   Per-service:     $BACKUP_CONFIG_DIR/services/*.env  (one file per database)
#
#   See backup/config.env.example and backup/services/service.env.example
#   in your server repo for templates.
#
# GLOBAL CONFIG VARIABLES (config.env)
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION
#   KEEP_DAILY (default 7), KEEP_WEEKLY (default 4), KEEP_MONTHLY (default 6)
#   ALERT_EMAIL, SMTP_HOST, SMTP_PORT, SMTP_TLS, SMTP_USER, SMTP_PASSWORD,
#   SMTP_FROM, NOTIFY_ON_SUCCESS
#
# PER-SERVICE VARIABLES (services/NAME.env)
#   SERVICE_NAME      Identifier used in tags and log messages.
#   CONTAINER_NAME    Docker container running PostgreSQL for this service.
#                     May be either the exact container name or the Compose
#                     service/container stem (e.g. jw_postgres).
#   RESTIC_REPOSITORY Restic repository URL (e.g. s3:s3.amazonaws.com/bucket/svc).
#   RESTIC_PASSWORD   Encryption passphrase for this service's repository.
#   DB_NAME           Database name inside the container.
#   DB_USER           PostgreSQL user inside the container.
#   DB_PASSWORD       Password (leave empty for trust/peer auth).
#   STDIN_FILENAME    Filename stored inside the snapshot (e.g. myapp-db.sql).
#   BACKUP_PATHS      Colon-separated host paths to back up alongside the database
#                     (e.g. /opt/apps/planka/data:/opt/apps/planka/backgrounds).
#                     Stored as a separate snapshot tagged SERVICE_NAME-files.
#                     Omit if the service has no file assets to back up.
#   OPTIONAL          Set to "true" to skip this service if the container is not
#                     running instead of failing the whole backup run (default: false).
#
# EXIT CODES
#   0   All services backed up successfully.
#   1   One or more steps failed; failure email sent if ALERT_EMAIL is set.
#
# LOCAL TESTING
#   BACKUP_CONFIG_DIR=./backup/local-test backup/backup.sh --dry-run
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

DRY_RUN=false
VERIFY=false
VERIFY_ONLY=false
FILTER_SERVICE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=true;  shift ;;
    --verify)   VERIFY=true;   shift ;;
    --verify-only) VERIFY=true; VERIFY_ONLY=true; shift ;;
    --service)  [[ -n "${2:-}" ]] || { echo "--service requires a NAME argument" >&2; exit 1; }
                FILTER_SERVICE="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--dry-run] [--verify] [--verify-only] [--service NAME]" >&2
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
RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/var/cache/restic}"

# Source global config (provides AWS creds, SMTP, retention defaults).
# When run via systemd the EnvironmentFile directive also loads these, but
# sourcing here makes the script self-contained for manual runs.
if [[ -f "$GLOBAL_CONFIG" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$GLOBAL_CONFIG"
  set +a
fi

export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$RESTIC_CACHE_DIR}"
export HOME="${HOME:-/root}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log()  { echo "[$(date -u +%H:%M:%SZ)] $*"; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*"; }
die()  { log "ERROR $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Dry-run wrapper
# ---------------------------------------------------------------------------
# run CMD [ARGS…] executes CMD or prints "DRY-RUN: CMD ARGS" depending on
# --dry-run. Use for commands that make external changes; read-only commands
# (e.g. `restic snapshots`) can be called directly.

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
# Notifications (msmtp)
# ---------------------------------------------------------------------------

_setup_msmtp() {
  local config_file tls
  config_file="$(mktemp /tmp/msmtprc.XXXXXX)"
  tls="${SMTP_TLS:-on}"

  {
    echo "defaults"
    if [[ "$tls" == "on" ]]; then
      echo "tls on"
      echo "tls_starttls on"
    else
      echo "tls off"
      echo "tls_starttls off"
    fi
    echo ""
    echo "account default"
    echo "host ${SMTP_HOST:-localhost}"
    echo "port ${SMTP_PORT:-587}"
    echo "from ${SMTP_FROM:-backup@localhost}"
    if [[ -n "${SMTP_USER:-}" ]]; then
      echo "auth plain"
      echo "user ${SMTP_USER}"
      echo "password ${SMTP_PASSWORD:-}"
    else
      echo "auth off"
    fi
  } > "$config_file"

  chmod 600 "$config_file"
  echo "$config_file"
}

send_notification() {
  local subject="$1" body="$2" recipient="${ALERT_EMAIL:-}"

  if [[ -z "$recipient" ]]; then
    warn "ALERT_EMAIL not set — skipping notification."
    return 0
  fi

  if "$DRY_RUN"; then
    echo "DRY-RUN: send email to $recipient — $subject"
    return 0
  fi

  local config_file
  config_file="$(_setup_msmtp)"

  if printf 'Subject: %s\n\n%s\n' "$subject" "$body" \
       | msmtp --file="$config_file" "$recipient"; then
    info "Notification sent to $recipient."
  else
    warn "Failed to send notification."
  fi

  rm -f "$config_file"
}

RESTIC_LAST_OUTPUT=""

normalise_error_detail() {
  printf '%s' "$1" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

is_lock_contention_output() {
  local output="$1"
  [[ "$output" == *"repo already locked"* || "$output" == *"repository is already locked"* || "$output" == *"unable to create lock in backend"* ]]
}

run_restic_with_lock_retry() {
  local service_name="$1"
  local operation="$2"
  shift 2

  local max_attempts="${RESTIC_LOCK_RETRY_ATTEMPTS:-4}"
  local sleep_seconds="${RESTIC_LOCK_RETRY_INITIAL_DELAY_SEC:-2}"
  local attempt=1
  local output="" exit_code=0

  while true; do
    output="$("$@" 2>&1)" || exit_code=$?
    printf '%s\n' "$output"

    if [[ "${exit_code:-0}" -eq 0 ]]; then
      RESTIC_LAST_OUTPUT="$output"
      return 0
    fi

    if ! is_lock_contention_output "$output" || [[ "$attempt" -ge "$max_attempts" ]]; then
      RESTIC_LAST_OUTPUT="$output"
      return "${exit_code:-1}"
    fi

    warn "[$service_name] ${operation} hit a repository lock; retrying in ${sleep_seconds}s (attempt ${attempt}/${max_attempts})..."
    sleep "$sleep_seconds"
    sleep_seconds=$((sleep_seconds * 2))
    attempt=$((attempt + 1))
    exit_code=0
  done
}

apply_retention() {
  local service_name="$1"
  local prune_mode="${2:-false}"
  local repo="$3"
  local password="$4"
  local keep_daily="${KEEP_DAILY:-7}"
  local keep_weekly="${KEEP_WEEKLY:-4}"
  local keep_monthly="${KEEP_MONTHLY:-6}"
  local -a forget_args=(
    --keep-daily "$keep_daily"
    --keep-weekly "$keep_weekly"
    --keep-monthly "$keep_monthly"
  )

  if [[ "$prune_mode" == "true" ]]; then
    info "[$service_name] Applying retention with prune (daily=$keep_daily, weekly=$keep_weekly, monthly=$keep_monthly)..."
    forget_args+=(--prune)
  else
    info "[$service_name] Applying retention (daily=$keep_daily, weekly=$keep_weekly, monthly=$keep_monthly)..."
  fi

  if ! RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD="$password" \
      run_restic_with_lock_retry "$service_name" "retention" \
      restic forget "${forget_args[@]}"; then
    if [[ "$prune_mode" == "true" ]]; then
      warn "[$service_name] Retention prune failed."
    else
      warn "[$service_name] Retention application failed."
    fi
    return 1
  fi

  if [[ "$prune_mode" == "true" ]]; then
    info "[$service_name] Retention prune complete."
  else
    info "[$service_name] Retention applied."
  fi
}

# ---------------------------------------------------------------------------
# Failure trap
# ---------------------------------------------------------------------------

_NOTIFICATION_SENT=false
RUN_STATE_DIR="$(mktemp -d /tmp/backup-state.XXXXXX)"

cleanup_run_state() {
  rm -rf "$RUN_STATE_DIR"
}

trap cleanup_run_state EXIT

record_failure() {
  local failure_id="$1"
  local display_name="$2"
  local phase="$3"
  local snapshot_state="$4"
  local detail="${5:-}"
  local failure_file="$RUN_STATE_DIR/${failure_id//[^A-Za-z0-9_.:-]/_}.failure"

  {
    printf 'display=%s\n' "$display_name"
    printf 'phase=%s\n' "$phase"
    printf 'snapshot=%s\n' "$snapshot_state"
    printf 'detail=%s\n' "$(normalise_error_detail "$detail")"
  } > "$failure_file"
}

build_failure_body() {
  local journal_unit="$1"
  shift

  local body
  body="$(printf 'Backup FAILED on %s at %s.\n\nMode: %s\n\nFailure details:\n' \
    "$(hostname)" "$TIMESTAMP" "$journal_unit")"

  local failure_id="" failure_file="" display="" phase="" snapshot="" detail=""
  for failure_id in "$@"; do
    failure_file="$RUN_STATE_DIR/${failure_id//[^A-Za-z0-9_.:-]/_}.failure"
    display="$failure_id"
    phase="unknown"
    snapshot="unknown"
    detail=""

    if [[ -f "$failure_file" ]]; then
      # shellcheck source=/dev/null
      source "$failure_file"
    fi

    body+=$(printf '  - %s: phase=%s, snapshot=%s\n' "$display" "$phase" "$snapshot")
    if [[ -n "$detail" ]]; then
      body+=$(printf '    detail: %s\n' "$detail")
    fi
  done

  body+=$(printf '\nCheck the system journal:\n  journalctl -u %s -n 100' "$journal_unit")
  printf '%s' "$body"
}

on_error() {
  local exit_code=$?
  local line_no="${1:-unknown}"
  local journal_unit="backup.service"

  if "$VERIFY_ONLY"; then
    journal_unit="backup-verify.service"
  fi

  warn "Backup failed at line $line_no (exit code $exit_code)."

  if ! "$_NOTIFICATION_SENT"; then
    local body
    body="$(printf \
      'Backup FAILED on %s at %s.\n\nScript: %s\nLine:   %s\nExit:   %s\nMode:   %s\n\nCheck the system journal:\n  journalctl -u %s -n 100' \
      "$(hostname)" "$TIMESTAMP" "$0" "$line_no" "$exit_code" "$journal_unit" "$journal_unit")"
    send_notification "[BACKUP FAILED] $(hostname) — $TIMESTAMP" "$body"
    _NOTIFICATION_SENT=true
  fi
}

trap 'on_error $LINENO' ERR

# ---------------------------------------------------------------------------
# Per-service backup
# ---------------------------------------------------------------------------

backup_service() {
  local env_file="$1"
  local failure_id="$2"
  local success_file="$RUN_STATE_DIR/${failure_id//[^A-Za-z0-9_.:-]/_}.backed_up"

  # Reset per-service variables before sourcing to prevent bleed-through
  # between services.
  local SERVICE_NAME="" CONTAINER_NAME="" DB_NAME="" DB_USER="" DB_PASSWORD=""
  local RESTIC_REPOSITORY="" RESTIC_PASSWORD="" STDIN_FILENAME="" BACKUP_PATHS=""
  local OPTIONAL="false"
  local RESOLVED_CONTAINER_NAME=""

  # shellcheck source=/dev/null
  source "$env_file"

  # Validate required variables.
  local var missing=0
  for var in SERVICE_NAME CONTAINER_NAME DB_NAME DB_USER RESTIC_REPOSITORY RESTIC_PASSWORD STDIN_FILENAME; do
    if [[ -z "${!var:-}" ]]; then
      warn "[$env_file] \$$var is not set — skipping this service."
      missing=1
    fi
  done
  if [[ $missing -ne 0 ]]; then
    record_failure "$failure_id" "$(basename "$env_file" .env)" "config" "no snapshot attempted" \
      "required service configuration is missing"
    return 1
  fi

  if ! RESOLVED_CONTAINER_NAME="$(resolve_container_name "$CONTAINER_NAME")"; then
    if [[ "$OPTIONAL" == "true" ]]; then
      warn "[$SERVICE_NAME] Container '$CONTAINER_NAME' is not available — skipping (OPTIONAL=true)."
      return 0
    fi
    warn "[$SERVICE_NAME] Container '$CONTAINER_NAME' could not be resolved."
    record_failure "$failure_id" "$SERVICE_NAME" "container" "no snapshot attempted" \
      "container '$CONTAINER_NAME' could not be resolved"
    return 1
  fi

  info "--- Service: $SERVICE_NAME ---"

  # If OPTIONAL=true, check container is running before attempting the backup.
  if [[ "$OPTIONAL" == "true" ]]; then
    local running
    running="$(docker inspect --format '{{.State.Running}}' "$RESOLVED_CONTAINER_NAME" 2>/dev/null || echo 'false')"
    if [[ "$running" != "true" ]]; then
      warn "[$SERVICE_NAME] Container '$RESOLVED_CONTAINER_NAME' is not running — skipping (OPTIONAL=true)."
      return 0
    fi
  fi

  info "[$SERVICE_NAME] Backing up ${DB_NAME} from container ${RESOLVED_CONTAINER_NAME}..."

  if "$DRY_RUN"; then
    echo "DRY-RUN: docker exec $RESOLVED_CONTAINER_NAME pg_dump $DB_NAME | restic backup --stdin --stdin-filename $STDIN_FILENAME --tag $SERVICE_NAME"
    return 0
  fi

  # Export per-service restic credentials so all restic calls use them.
  export RESTIC_REPOSITORY RESTIC_PASSWORD

  # Initialise the repository if this is the first run.
  if ! restic snapshots --no-lock &>/dev/null; then
    info "[$SERVICE_NAME] Initialising new Restic repository at ${RESTIC_REPOSITORY}..."
    if ! restic init; then
      warn "[$SERVICE_NAME] Failed to initialise Restic repository."
      record_failure "$failure_id" "$SERVICE_NAME" "repository-init" "no snapshot attempted" \
        "restic init failed"
      return 1
    fi
  fi

  # Dump the database via docker exec directly into restic (no temp file).
  # Using the container's own pg_dump avoids version mismatches.
  if ! docker exec \
      -e PGPASSWORD="${DB_PASSWORD:-}" \
      "$RESOLVED_CONTAINER_NAME" \
      pg_dump \
        --username "$DB_USER" \
        --no-password \
        "$DB_NAME" \
    | restic backup \
        --stdin \
        --stdin-filename "$STDIN_FILENAME" \
        --tag "$SERVICE_NAME" \
        --tag "$TIMESTAMP"; then
    warn "[$SERVICE_NAME] Database backup failed."
    record_failure "$failure_id" "$SERVICE_NAME" "backup" "snapshot not saved" \
      "database snapshot upload failed"
    return 1
  fi

  info "[$SERVICE_NAME] Backup complete."

  # Back up file paths if configured (separate snapshot, tagged SERVICE_NAME-files).
  # The existing restic forget below covers both DB and file snapshots — restic
  # groups them by path so retention is applied to each independently.
  if [[ -n "${BACKUP_PATHS:-}" ]]; then
    info "[$SERVICE_NAME] Backing up file paths..."
    local -a _paths
    IFS=: read -ra _paths <<< "$BACKUP_PATHS"
    if ! restic backup \
      "${_paths[@]}" \
      --tag "${SERVICE_NAME}-files" \
      --tag "$TIMESTAMP"; then
      warn "[$SERVICE_NAME] File backup failed."
      record_failure "$failure_id" "$SERVICE_NAME" "file-backup" "database snapshot saved" \
        "file snapshot upload failed"
      return 1
    fi
    info "[$SERVICE_NAME] File backup complete."
  fi

  : > "$success_file"
}

# ---------------------------------------------------------------------------
# Optional post-backup verification
# ---------------------------------------------------------------------------

verify_service() {
  local env_file="$1"
  local failure_id="$2"
  local success_file="$RUN_STATE_DIR/${failure_id//[^A-Za-z0-9_.:-]/_}.verified"

  local SERVICE_NAME="" RESTIC_REPOSITORY="" RESTIC_PASSWORD=""
  local CONTAINER_NAME="" DB_NAME="" DB_USER="" DB_PASSWORD=""
  local STDIN_FILENAME="" OPTIONAL="false"
  # shellcheck source=/dev/null
  source "$env_file"

  export RESTIC_REPOSITORY RESTIC_PASSWORD

  info "[$SERVICE_NAME] Verifying repository integrity..."
  if ! run restic check; then
    warn "[$SERVICE_NAME] Repository verification failed."
    record_failure "$failure_id" "$SERVICE_NAME [verify]" "verify" "no backup attempted" \
      "restic check failed"
    return 1
  fi
  info "[$SERVICE_NAME] Repository OK."

  info "[$SERVICE_NAME] Recent snapshots:"
  if ! restic snapshots --latest 5; then
    warn "[$SERVICE_NAME] Failed to list recent snapshots."
    record_failure "$failure_id" "$SERVICE_NAME [verify]" "snapshot-list" "no backup attempted" \
      "failed to list recent snapshots"
    return 1
  fi

  : > "$success_file"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  local journal_unit="backup.service"
  local run_mode_label="backup"

  if "$VERIFY_ONLY"; then
    journal_unit="backup-verify.service"
    run_mode_label="verify-only"
  elif "$VERIFY"; then
    run_mode_label="backup+verify"
  fi

  info "================================================================="
  info "Backup started — $TIMESTAMP"
  "$DRY_RUN" && info "(dry-run mode — no changes will be made)"
  info "Mode: $run_mode_label"
  info "Config: $CONFIG_DIR"
  info "================================================================="

  # Collect service env files.
  local service_files=()

  if [[ -n "$FILTER_SERVICE" ]]; then
    local target="$SERVICES_DIR/${FILTER_SERVICE}.env"
    [[ -f "$target" ]] || die "Service config not found: $target"
    service_files=("$target")
  else
    # Glob — the [[ -f ]] guard handles the no-match case on all bash versions.
    for f in "$SERVICES_DIR"/*.env; do
      [[ -f "$f" ]] && service_files+=("$f")
    done
    [[ ${#service_files[@]} -gt 0 ]] || die "No service configs found in $SERVICES_DIR/"
  fi

  info "Services to back up: ${#service_files[@]}"

  # Run each service in a subshell so a failure in one does not abort the
  # others. Failures are accumulated and reported together at the end.
  local failed_services=()
  local failed_failure_ids=()
  local retention_labels=()
  local retention_repos=()
  local retention_passwords=()
  local env_file="" failure_label="" failure_id=""

  queue_retention() {
    local label="$1"
    local repo="$2"
    local password="$3"
    local idx=0

    for idx in "${!retention_repos[@]}"; do
      if [[ "${retention_repos[$idx]}" == "$repo" && "${retention_passwords[$idx]}" == "$password" ]]; then
        case ",${retention_labels[$idx]}," in
          *",$label,"*) ;;
          *) retention_labels[$idx]="${retention_labels[$idx]},$label" ;;
        esac
        return 0
      fi
    done

    retention_labels+=("$label")
    retention_repos+=("$repo")
    retention_passwords+=("$password")
  }

  if ! "$VERIFY_ONLY"; then
    for env_file in "${service_files[@]}"; do
      failure_label="$(basename "$env_file" .env)"
      failure_id="backup:${failure_label}"
      if ! ( backup_service "$env_file" "$failure_id" ); then
        failed_services+=("$failure_label")
        failed_failure_ids+=("$failure_id")
        continue
      fi

      if [[ ! -f "$RUN_STATE_DIR/${failure_id//[^A-Za-z0-9_.:-]/_}.backed_up" ]]; then
        continue
      fi

      local SERVICE_NAME="" RESTIC_REPOSITORY="" RESTIC_PASSWORD=""
      # shellcheck source=/dev/null
      source "$env_file"
      queue_retention "$SERVICE_NAME" "$RESTIC_REPOSITORY" "$RESTIC_PASSWORD"
    done

    local idx=0
    for idx in "${!retention_repos[@]}"; do
      if ! apply_retention "${retention_labels[$idx]}" "false" "${retention_repos[$idx]}" "${retention_passwords[$idx]}"; then
        failure_label="${retention_labels[$idx]}"
        failure_id="retention:${failure_label}"
        failed_services+=("$failure_label")
        failed_failure_ids+=("$failure_id")
        record_failure "$failure_id" "$failure_label" "retention" "snapshot saved" "$RESTIC_LAST_OUTPUT"
      fi
    done
  fi

  if "$VERIFY"; then
    info "================================================================="
    if "$VERIFY_ONLY"; then
      info "Running verification-only pass..."
    else
      info "Running post-backup verification..."
    fi
    retention_labels=()
    retention_repos=()
    retention_passwords=()
    for env_file in "${service_files[@]}"; do
      failure_label="$(basename "$env_file" .env)"
      failure_id="verify:${failure_label}"
      if ! ( verify_service "$env_file" "$failure_id" ); then
        failed_services+=("${failure_label} [verify]")
        failed_failure_ids+=("$failure_id")
        continue
      fi

      if [[ ! -f "$RUN_STATE_DIR/${failure_id//[^A-Za-z0-9_.:-]/_}.verified" ]]; then
        continue
      fi

      local SERVICE_NAME="" RESTIC_REPOSITORY="" RESTIC_PASSWORD=""
      # shellcheck source=/dev/null
      source "$env_file"
      queue_retention "$SERVICE_NAME" "$RESTIC_REPOSITORY" "$RESTIC_PASSWORD"
    done

    local idx=0
    for idx in "${!retention_repos[@]}"; do
      if ! apply_retention "${retention_labels[$idx]}" "true" "${retention_repos[$idx]}" "${retention_passwords[$idx]}"; then
        failure_label="${retention_labels[$idx]}"
        failure_id="verify-retention:${failure_label}"
        failed_services+=("${failure_label} [verify]")
        failed_failure_ids+=("$failure_id")
        record_failure "$failure_id" "${failure_label} [verify]" "retention-prune" "no backup attempted" "$RESTIC_LAST_OUTPUT"
      fi
    done
  fi

  if [[ ${#failed_services[@]} -gt 0 ]]; then
    warn "================================================================="
    warn "The following services failed:"
    for svc in "${failed_services[@]}"; do
      warn "  - $svc"
    done
    warn "================================================================="
    local body
    body="$(build_failure_body "$journal_unit" "${failed_failure_ids[@]}")"
    _NOTIFICATION_SENT=true
    send_notification "[BACKUP FAILED] $(hostname) — $TIMESTAMP" "$body"
    exit 1
  fi

  info "================================================================="
  info "All services backed up successfully."
  info "================================================================="

  if [[ "${NOTIFY_ON_SUCCESS:-false}" == "true" ]]; then
    local body
    body="$(printf \
      'Backup completed successfully on %s at %s.\n\nServices: %s\nConfig:   %s' \
      "$(hostname)" "$TIMESTAMP" "${#service_files[@]}" "$CONFIG_DIR")"
    send_notification "[BACKUP OK] $(hostname) — $TIMESTAMP" "$body"
  fi
}

main
