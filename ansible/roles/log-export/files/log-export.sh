#!/usr/bin/env bash
# =============================================================================
# log-export.sh — Ship a hash-chained log archive off-host (ISM-1988/1815).
# =============================================================================
#
# Installed by the log-export role, run nightly by log-export.timer.
#
#   1. journalctl --cursor-file  → everything new in the journal since the
#      last export (auditd, auth, sshd, sudo, app units — the lot).
#   2. Files under EXTRA_PATHS modified since the last run (raw audit.log
#      rotations, Caddy JSON access logs).
#   3. tar --zstd → archive; SHA-256 chained onto the previous archive's
#      hash in hash-chain.log (GENESIS for the first link).
#   4. aws s3 cp to $LOG_EXPORT_S3_URI/<host>/<year>/ — an Object-Locked,
#      write-only-credential bucket (see role defaults for the IAM shape).
#
# Failed uploads stay in $STATE_DIR/pending/ and are retried on the next run
# BEFORE the new archive, preserving chain order. Any remaining failure exits
# non-zero → OnFailure=notify@.
# =============================================================================

set -euo pipefail

ENV_FILE="${LOG_EXPORT_ENV:-/etc/vps-scaffold/log-export.env}"
# shellcheck source=/dev/null
[[ -r "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }

S3_URI="${LOG_EXPORT_S3_URI:-}"
STATE_DIR="${STATE_DIR:-/var/lib/log-export}"
EXTRA_PATHS="${EXTRA_PATHS:-/var/log/audit:/var/lib/docker/volumes/caddy_logs/_data}"

log() { echo "[$(date -u +%H:%M:%SZ)] $*"; }

if [[ -z "$S3_URI" ]]; then
  log "LOG_EXPORT_S3_URI not set — log export is configured but inert."
  exit 0
fi

HOST="$(hostname -s)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
YEAR="$(date -u +%Y)"
PENDING="$STATE_DIR/pending"
WORK="$STATE_DIR/work"
CHAIN="$STATE_DIR/hash-chain.log"
CURSOR="$STATE_DIR/journal.cursor"
NEWER_STAMP="$STATE_DIR/last-run.stamp"

mkdir -p "$PENDING" "$WORK"
chmod 750 "$STATE_DIR" "$PENDING" "$WORK"
rm -rf "${WORK:?}"/*

# --- 1. journal since last export (cursor-file is created/advanced for us) ---
journalctl --cursor-file="$CURSOR" -o export --no-pager > "$WORK/journal.export" || true

# --- 2. extra file trees, incremental on mtime ---
mkdir -p "$WORK/files"
IFS=: read -ra extra <<< "$EXTRA_PATHS"
for p in "${extra[@]}"; do
  [[ -e "$p" ]] || continue
  if [[ -f "$NEWER_STAMP" ]]; then
    find "$p" -type f -newer "$NEWER_STAMP" -exec cp -a --parents {} "$WORK/files/" \; 2>/dev/null || true
  else
    find "$p" -type f -exec cp -a --parents {} "$WORK/files/" \; 2>/dev/null || true
  fi
done

if [[ ! -s "$WORK/journal.export" ]] && ! find "$WORK/files" -type f -print -quit 2>/dev/null | grep -q .; then
  log "Nothing new to export."
  touch "$NEWER_STAMP"
  exit 0
fi

# --- 3. archive + hash chain ---
ARCHIVE="$PENDING/logs-$HOST-$STAMP.tar.zst"
tar --zstd -C "$WORK" -cf "$ARCHIVE" .

prev="GENESIS"
if [[ -s "$CHAIN" ]]; then
  prev="$(tail -n1 "$CHAIN" | awk '{print $NF}')"
fi
archive_sha="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
link_sha="$(printf '%s %s' "$prev" "$archive_sha" | sha256sum | awk '{print $1}')"
printf '%s %s %s %s\n' "$STAMP" "$(basename "$ARCHIVE")" "$archive_sha" "$link_sha" >> "$CHAIN"
chmod 640 "$CHAIN"

# --- 4. upload pending archives oldest-first, then the chain file ---
fail=0
while IFS= read -r f; do
  base="$(basename "$f")"
  if aws s3 cp --only-show-errors "$f" "$S3_URI/$HOST/$YEAR/$base"; then
    log "Uploaded $base"
    rm -f "$f"
  else
    log "Upload FAILED for $base — kept in pending/"
    fail=1
  fi
done < <(find "$PENDING" -name 'logs-*.tar.zst' -type f | sort)

if ! aws s3 cp --only-show-errors "$CHAIN" "$S3_URI/$HOST/hash-chain.log"; then
  log "Upload FAILED for hash-chain.log"
  fail=1
fi

touch "$NEWER_STAMP"
rm -rf "${WORK:?}"/*

if [[ $fail -ne 0 ]]; then
  log "Log export finished with upload failures — will retry next run."
  exit 1
fi
log "Log export complete."
