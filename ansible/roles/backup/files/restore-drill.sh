#!/usr/bin/env bash
# =============================================================================
# restore-drill.sh — Prove the backups restore, and record RPO/RTO evidence.
# =============================================================================
#
# For every configured service, restore the LATEST snapshot somewhere harmless
# and verify it:
#   - DB services:    restore.sh --target <db>_drill --no-files restores into a
#                     throwaway database in the live PostgreSQL container (the
#                     real restore path, including its table-count verification),
#                     which is then dropped.
#   - files-only:     restic restore into a scratch directory, asserted
#                     non-empty, then deleted.
#
# Live data is never touched: --no-files skips the restore-to-/ file step and
# the drill database name never equals the live one.
#
# Each drill appends a dated report to $DRILL_STATE_DIR recording, per service:
#   snapshot id, snapshot age (achieved RPO), restore duration (achieved RTO),
#   and PASS/FAIL. A FAIL exits non-zero so restore-drill.service fires its
#   OnFailure=notify@ push.
#
# USAGE
#   restore-drill.sh [--service NAME]... [--max-rpo-seconds N]
#
#   --service NAME        Drill only the named service(s). Default: all.
#   --max-rpo-seconds N   Fail a service whose latest snapshot is older than N
#                         seconds (default 93600 = 26 h; hourly backups plus
#                         slack). Set 0 to disable the age check.
# =============================================================================

set -euo pipefail

CONFIG_DIR="${BACKUP_CONFIG_DIR:-/etc/restic}"
GLOBAL_CONFIG="$CONFIG_DIR/config.env"
SERVICES_DIR="$CONFIG_DIR/services"
RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/var/cache/restic}"
DRILL_STATE_DIR="${DRILL_STATE_DIR:-/var/lib/backup-drill}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESTORE_SH="$SCRIPT_DIR/restore.sh"

MAX_RPO_SECONDS=93600
SERVICE_NAMES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service)  [[ -n "${2:-}" ]] || { echo "--service requires a NAME argument" >&2; exit 1; }
                SERVICE_NAMES+=("$2"); shift 2 ;;
    --max-rpo-seconds) MAX_RPO_SECONDS="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--service NAME]... [--max-rpo-seconds N]" >&2
      exit 1
      ;;
  esac
done

if [[ -f "$GLOBAL_CONFIG" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$GLOBAL_CONFIG"
  set +a
fi

export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$RESTIC_CACHE_DIR}"
export HOME="${HOME:-/root}"

log()  { echo "[$(date -u +%H:%M:%SZ)] $*"; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*"; }
die()  { log "ERROR $*" >&2; exit 1; }

[[ -x "$RESTORE_SH" ]] || die "restore.sh not found/executable at $RESTORE_SH"

mkdir -p "$DRILL_STATE_DIR"
chmod 750 "$DRILL_STATE_DIR"

RUN_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="$DRILL_STATE_DIR/drill-$RUN_STAMP.txt"

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
  return 1
}

# Prints "<short_id> <age_seconds>" for the latest snapshot with the given tag,
# or "NONE 0" when the repository has no matching snapshot.
latest_snapshot() {
  local tag="$1"
  (restic snapshots --json --latest 1 --tag "$tag" 2>/dev/null || true) | python3 -c '
import json, re, sys
from datetime import datetime, timezone

try:
    snaps = json.load(sys.stdin) or []
except ValueError:
    snaps = []
if not snaps:
    print("NONE 0")
    sys.exit(0)
snap = snaps[-1]
# Normalise restic RFC3339 nanosecond timestamps for fromisoformat.
t = re.sub(r"(\.\d{6})\d+", r"\1", snap["time"]).replace("Z", "+00:00")
age = int((datetime.now(timezone.utc) - datetime.fromisoformat(t)).total_seconds())
sid = snap.get("short_id", "unknown")
print(f"{sid} {age}")
'
}

format_duration() {
  local s="$1"
  printf '%dh%02dm%02ds' $((s / 3600)) $(((s % 3600) / 60)) $((s % 60))
}

# ---------------------------------------------------------------------------
# Per-service drill — always invoked in a subshell, so env vars never bleed
# across services, a failure in one service does not abort the rest, and the
# EXIT traps below clean up when the subshell ends however it ends.
# ---------------------------------------------------------------------------

drill_service() {
  local env_file="$1"
  local svc
  svc="$(basename "$env_file" .env)"

  local SERVICE_NAME="" CONTAINER_NAME="" DB_NAME="" DB_USER="" DB_PASSWORD=""
  # shellcheck disable=SC2034  # reset before source to prevent bleed-through
  local RESTIC_REPOSITORY="" RESTIC_PASSWORD="" STDIN_FILENAME="" BACKUP_PATHS=""
  # shellcheck source=/dev/null
  source "$env_file"

  [[ -n "$SERVICE_NAME" && -n "$RESTIC_REPOSITORY" && -n "$RESTIC_PASSWORD" ]] \
    || { warn "[$svc] Incomplete service config — cannot drill."; return 1; }

  export RESTIC_REPOSITORY RESTIC_PASSWORD

  local files_only="false" tag="$SERVICE_NAME"
  if [[ -z "${DB_NAME:-}" ]]; then
    files_only="true"
    tag="${SERVICE_NAME}-files"
  fi

  local snap_id age
  read -r snap_id age < <(latest_snapshot "$tag")
  if [[ "$snap_id" == "NONE" ]]; then
    warn "[$svc] No snapshot with tag '$tag' found — nothing to drill."
    echo "$svc | mode=$([[ "$files_only" == "true" ]] && echo files || echo db) | snapshot=NONE | rpo=n/a | rto=n/a | FAIL (no snapshot)" >> "$REPORT"
    return 1
  fi

  local rpo_note rpo_fail=""
  rpo_note="rpo=$(format_duration "$age")"
  if [[ "$MAX_RPO_SECONDS" -gt 0 && "$age" -gt "$MAX_RPO_SECONDS" ]]; then
    rpo_fail="latest snapshot older than $(format_duration "$MAX_RPO_SECONDS")"
  fi

  local start rto
  start="$(date +%s)"

  if [[ "$files_only" == "true" ]]; then
    info "[$svc] Drilling files-only restore of snapshot $snap_id into a scratch dir..."
    local scratch
    scratch="$(mktemp -d /var/tmp/restore-drill.XXXXXX)"
    # shellcheck disable=SC2064  # expand scratch now, not at trap time
    trap "rm -rf '$scratch'" EXIT

    if ! restic restore latest --tag "$tag" --target "$scratch" > /dev/null; then
      warn "[$svc] restic restore failed."
      echo "$svc | mode=files | snapshot=$snap_id | $rpo_note | rto=n/a | FAIL (restore error)" >> "$REPORT"
      return 1
    fi
    if ! find "$scratch" -type f -print -quit | grep -q .; then
      warn "[$svc] Restored snapshot contains no files."
      echo "$svc | mode=files | snapshot=$snap_id | $rpo_note | rto=n/a | FAIL (empty restore)" >> "$REPORT"
      return 1
    fi
  else
    local container
    if ! container="$(resolve_container_name "$CONTAINER_NAME")"; then
      warn "[$svc] Container '$CONTAINER_NAME' could not be resolved."
      echo "$svc | mode=db | snapshot=$snap_id | $rpo_note | rto=n/a | FAIL (no container)" >> "$REPORT"
      return 1
    fi

    local drill_db="${DB_NAME}_drill"
    drop_drill_db() {
      docker exec -e PGPASSWORD="${DB_PASSWORD:-}" "$container" \
        psql --username "$DB_USER" --no-password --dbname postgres \
        --command "DROP DATABASE IF EXISTS \"$drill_db\";" < /dev/null > /dev/null 2>&1 || true
    }
    trap drop_drill_db EXIT

    info "[$svc] Drilling DB restore of snapshot $snap_id into throwaway database '$drill_db'..."
    drop_drill_db  # clear any leftover from an aborted previous drill

    # The real restore path: restore.sh verifies the restored DB is non-empty.
    if ! RESTORE_NO_CONFIRM=true "$RESTORE_SH" --service "$svc" --target "$drill_db" --no-files > /dev/null; then
      warn "[$svc] restore.sh failed."
      echo "$svc | mode=db | snapshot=$snap_id | $rpo_note | rto=n/a | FAIL (restore error)" >> "$REPORT"
      return 1
    fi
  fi

  rto="$(( $(date +%s) - start ))"

  if [[ -n "$rpo_fail" ]]; then
    warn "[$svc] Restore succeeded but RPO check failed: $rpo_fail."
    echo "$svc | mode=$([[ "$files_only" == "true" ]] && echo files || echo db) | snapshot=$snap_id | $rpo_note | rto=$(format_duration "$rto") | FAIL ($rpo_fail)" >> "$REPORT"
    return 1
  fi

  info "[$svc] Drill passed — RPO $(format_duration "$age"), RTO $(format_duration "$rto")."
  echo "$svc | mode=$([[ "$files_only" == "true" ]] && echo files || echo db) | snapshot=$snap_id | $rpo_note | rto=$(format_duration "$rto") | PASS" >> "$REPORT"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  local service_files=()

  if [[ ${#SERVICE_NAMES[@]} -gt 0 ]]; then
    local name
    for name in "${SERVICE_NAMES[@]}"; do
      local f="$SERVICES_DIR/${name}.env"
      [[ -f "$f" ]] || die "Service config not found: $f"
      service_files+=("$f")
    done
  else
    local f
    for f in "$SERVICES_DIR"/*.env; do
      [[ -f "$f" ]] && service_files+=("$f")
    done
    [[ ${#service_files[@]} -gt 0 ]] || die "No service configs found in $SERVICES_DIR/"
  fi

  {
    echo "Restore drill — $(hostname) — $RUN_STAMP"
    echo "max RPO: $(format_duration "$MAX_RPO_SECONDS") | services: ${#service_files[@]}"
    echo "---"
  } > "$REPORT"

  info "Restore drill started — report: $REPORT"

  local failed=0 env_file=""
  for env_file in "${service_files[@]}"; do
    if ! ( drill_service "$env_file" ); then
      failed=$((failed + 1))
    fi
  done

  {
    echo "---"
    echo "RESULT: $([[ $failed -eq 0 ]] && echo PASS || echo "FAIL ($failed service(s))")"
  } >> "$REPORT"

  ln -sf "$(basename "$REPORT")" "$DRILL_STATE_DIR/latest.txt"
  cat "$REPORT"

  [[ $failed -eq 0 ]] || die "Restore drill failed for $failed service(s) — see $REPORT"
  info "Restore drill complete — all services PASS."
}

main
