#!/usr/bin/env bash
# =============================================================================
# backup.sh — Back up PostgreSQL databases to Restic repositories.
# =============================================================================
#
# USAGE
#   backup.sh [--dry-run] [--verify] [--service NAME]
#
#   --dry-run         Print every command that would run; make no changes.
#   --verify          After backing up, run `restic check` and list snapshots.
#   --service NAME    Back up only the named service (default: all services).
#
# CONFIGURATION
#   Global config:   $BACKUP_CONFIG_DIR/config.env     (default: /etc/restic/config.env)
#   Per-service:     $BACKUP_CONFIG_DIR/services/*.env  (one file per database)
#
#   See backup/config.env.example and backup/services/example.env.example
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
FILTER_SERVICE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=true;  shift ;;
    --verify)   VERIFY=true;   shift ;;
    --service)  [[ -n "${2:-}" ]] || { echo "--service requires a NAME argument" >&2; exit 1; }
                FILTER_SERVICE="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--dry-run] [--verify] [--service NAME]" >&2
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

# Source global config (provides AWS creds, SMTP, retention defaults).
# When run via systemd the EnvironmentFile directive also loads these, but
# sourcing here makes the script self-contained for manual runs.
if [[ -f "$GLOBAL_CONFIG" ]]; then
  # shellcheck source=/dev/null
  source "$GLOBAL_CONFIG"
fi

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

# ---------------------------------------------------------------------------
# Notifications (msmtp)
# ---------------------------------------------------------------------------

_setup_msmtp() {
  local config_file tls
  config_file="$(mktemp /tmp/msmtprc.XXXXXX)"
  tls="${SMTP_TLS:-on}"

  {
    echo "defaults"
    echo "logfile /tmp/msmtp.log"
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
    warn "Failed to send notification — check /tmp/msmtp.log."
  fi

  rm -f "$config_file"
}

# ---------------------------------------------------------------------------
# Failure trap
# ---------------------------------------------------------------------------

_NOTIFICATION_SENT=false

on_error() {
  local exit_code=$?
  local line_no="${1:-unknown}"

  warn "Backup failed at line $line_no (exit code $exit_code)."

  if ! "$_NOTIFICATION_SENT"; then
    local body
    body="$(printf \
      'Backup FAILED on %s at %s.\n\nScript: %s\nLine:   %s\nExit:   %s\n\nCheck the system journal:\n  journalctl -u backup.service -n 100' \
      "$(hostname)" "$TIMESTAMP" "$0" "$line_no" "$exit_code")"
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

  # Reset per-service variables before sourcing to prevent bleed-through
  # between services.
  local SERVICE_NAME="" CONTAINER_NAME="" DB_NAME="" DB_USER="" DB_PASSWORD=""
  local RESTIC_REPOSITORY="" RESTIC_PASSWORD="" STDIN_FILENAME="" BACKUP_PATHS=""
  local OPTIONAL="false"

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
  [[ $missing -eq 0 ]] || return 1

  info "--- Service: $SERVICE_NAME ---"

  # If OPTIONAL=true, check container is running before attempting the backup.
  if [[ "$OPTIONAL" == "true" ]]; then
    local running
    running="$(docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo 'false')"
    if [[ "$running" != "true" ]]; then
      warn "[$SERVICE_NAME] Container '$CONTAINER_NAME' is not running — skipping (OPTIONAL=true)."
      return 0
    fi
  fi

  info "[$SERVICE_NAME] Backing up ${DB_NAME} from container ${CONTAINER_NAME}..."

  if "$DRY_RUN"; then
    echo "DRY-RUN: docker exec $CONTAINER_NAME pg_dump $DB_NAME | restic backup --stdin --stdin-filename $STDIN_FILENAME --tag $SERVICE_NAME"
    return 0
  fi

  # Export per-service restic credentials so all restic calls use them.
  export RESTIC_REPOSITORY RESTIC_PASSWORD

  # Initialise the repository if this is the first run.
  if ! restic snapshots --no-lock &>/dev/null; then
    info "[$SERVICE_NAME] Initialising new Restic repository at ${RESTIC_REPOSITORY}..."
    restic init
  fi

  # Dump the database via docker exec directly into restic (no temp file).
  # Using the container's own pg_dump avoids version mismatches.
  docker exec \
      -e PGPASSWORD="${DB_PASSWORD:-}" \
      "$CONTAINER_NAME" \
      pg_dump \
        --username "$DB_USER" \
        --no-password \
        "$DB_NAME" \
    | restic backup \
        --stdin \
        --stdin-filename "$STDIN_FILENAME" \
        --tag "$SERVICE_NAME" \
        --tag "$TIMESTAMP"

  info "[$SERVICE_NAME] Backup complete."

  # Back up file paths if configured (separate snapshot, tagged SERVICE_NAME-files).
  # The existing restic forget below covers both DB and file snapshots — restic
  # groups them by path so retention is applied to each independently.
  if [[ -n "${BACKUP_PATHS:-}" ]]; then
    info "[$SERVICE_NAME] Backing up file paths..."
    local -a _paths
    IFS=: read -ra _paths <<< "$BACKUP_PATHS"
    restic backup \
      "${_paths[@]}" \
      --tag "${SERVICE_NAME}-files" \
      --tag "$TIMESTAMP"
    info "[$SERVICE_NAME] File backup complete."
  fi

  # Apply retention policy to this service's repository.
  local keep_daily="${KEEP_DAILY:-7}"
  local keep_weekly="${KEEP_WEEKLY:-4}"
  local keep_monthly="${KEEP_MONTHLY:-6}"

  info "[$SERVICE_NAME] Applying retention (daily=$keep_daily, weekly=$keep_weekly, monthly=$keep_monthly)..."
  restic forget \
    --keep-daily   "$keep_daily"  \
    --keep-weekly  "$keep_weekly" \
    --keep-monthly "$keep_monthly" \
    --prune
  info "[$SERVICE_NAME] Retention applied."
}

# ---------------------------------------------------------------------------
# Optional post-backup verification
# ---------------------------------------------------------------------------

verify_service() {
  local env_file="$1"

  local SERVICE_NAME="" RESTIC_REPOSITORY="" RESTIC_PASSWORD=""
  local CONTAINER_NAME="" DB_NAME="" DB_USER="" DB_PASSWORD=""
  local STDIN_FILENAME="" OPTIONAL="false"
  # shellcheck source=/dev/null
  source "$env_file"

  export RESTIC_REPOSITORY RESTIC_PASSWORD

  info "[$SERVICE_NAME] Verifying repository integrity..."
  run restic check
  info "[$SERVICE_NAME] Repository OK."

  info "[$SERVICE_NAME] Recent snapshots:"
  restic snapshots --latest 5
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  info "================================================================="
  info "Backup started — $TIMESTAMP"
  "$DRY_RUN" && info "(dry-run mode — no changes will be made)"
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

  for env_file in "${service_files[@]}"; do
    if ! ( backup_service "$env_file" ); then
      failed_services+=("$(basename "$env_file" .env)")
    fi
  done

  if "$VERIFY"; then
    info "================================================================="
    info "Running post-backup verification..."
    for env_file in "${service_files[@]}"; do
      if ! ( verify_service "$env_file" ); then
        failed_services+=("$(basename "$env_file" .env) [verify]")
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
    body="$(printf \
      'Backup FAILED on %s at %s.\n\nFailed services:\n%s\n\nCheck the system journal:\n  journalctl -u backup.service -n 100' \
      "$(hostname)" "$TIMESTAMP" "$(printf '  - %s\n' "${failed_services[@]}")")"
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
