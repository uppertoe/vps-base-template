#!/usr/bin/env bash
# =============================================================================
# vuln-scan.sh — Scan the RUNNING container images for CVEs with Trivy.
# =============================================================================
#
# Installed by the vuln-scan Ansible role and run daily by vuln-scan.timer.
# Same scan model as ansible/audit-vuln.yml, but on-host and scheduled: dated
# reports accumulate under $STATE_DIR as patch-SLA evidence, and a fixable
# CRITICAL that has outstayed the self-heal grace window pushes an urgent
# alert via vps-notify (no-op until configured).
#
# Images are scanned BY IMAGE ID, not by repo:tag. Tag refs lie twice on a
# digest-pinned host: pulls by digest never move the local :latest tag (so a
# tag ref scans a stale image that is no longer running), and when no local
# tag exists Trivy pulls the registry's current tag (an image that may not be
# deployed yet). The ID is exactly what the container runs.
#
# Alerting is grace-aware: the hands-off update pipeline (weekly app-image
# rebuilds → Renovate digest PRs → auto-deploy timer) is expected to clear a
# fixable CRITICAL by itself within days. Each finding's first-seen date is
# tracked in $STATE_DIR/first-seen.json; the urgent ntfy alert only fires for
# findings still present after $GRACE_DAYS. Every fixable finding still lands
# in the dated summary the day it appears — the grace period gates the page,
# not the record. NOTE: tighten GRACE_DAYS (and the rebuild cadence) if this
# deployment must demonstrate a strict 48-hour critical-patch SLA.
#
# Report-only by design: findings never block anything. The script exits
# non-zero only when the scan itself could not run (Docker down, Trivy pull
# failed), which fires the unit's OnFailure=notify@ hook.
#
# Configuration comes from the systemd unit (Environment=) or the shell:
#   TRIVY_IMAGE, SEVERITY, CACHE_DIR, STATE_DIR, RETENTION_DAYS, GRACE_DAYS
# =============================================================================

set -euo pipefail

TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy:0.59.1}"
SEVERITY="${SEVERITY:-HIGH,CRITICAL}"
CACHE_DIR="${CACHE_DIR:-/var/cache/trivy}"
STATE_DIR="${STATE_DIR:-/var/lib/vuln-scan}"
RETENTION_DAYS="${RETENTION_DAYS:-400}"
GRACE_DAYS="${GRACE_DAYS:-8}"

DATE_UTC="$(date -u +%F)"
OUT_DIR="$STATE_DIR/$DATE_UTC"
FIRST_SEEN="$STATE_DIR/first-seen.json"

log() { echo "[$(date -u +%H:%M:%SZ)] $*"; }

mkdir -p "$CACHE_DIR" "$OUT_DIR"
chmod 750 "$STATE_DIR" "$OUT_DIR"

# Distinct images backing the running containers, as "<image-id> <configured
# ref>" pairs: the ID is what gets scanned, the ref is only for readable
# report names. Dedupe on the ID (several containers often share one image).
mapfile -t image_pairs < <(
  docker ps -q | xargs -r docker inspect --format '{{.Image}} {{.Config.Image}}' \
    | grep -v -F "$TRIVY_IMAGE" | sort -u | awk '!seen[$1]++' || true
)
if [[ ${#image_pairs[@]} -eq 0 ]]; then
  log "No running containers found — nothing to scan."
  echo "TOTAL HIGH=0 CRITICAL=0 CRITICAL_FIXABLE=0 OVERDUE=0 (no running containers)" > "$OUT_DIR/summary.txt"
  exit 0
fi

# Pull trivy once so the per-image runs don't each block on a pull.
docker pull -q "$TRIVY_IMAGE" >/dev/null

# Resource caps on the Trivy container (this is the effective lever — the
# systemd unit's CPUWeight/MemoryHigh do not reach a docker-run child, which
# lives in dockerd's cgroup). On the 2 GB host, cap Trivy at 1 GiB with swap
# disabled for the container (--memory-swap == --memory) so a scan can never
# push the box into swap, and give it a low CPU share so it yields to the app
# tier under contention. 1 GiB is generous for the handful of small images here.
TRIVY_LIMITS=(--memory=1g --memory-swap=1g --cpu-shares=256)
for pair in "${image_pairs[@]}"; do
  image_id="${pair%% *}"
  ref="${pair#* }"
  # Report name from the configured ref minus any @sha256 pin — stable across
  # digest bumps, so day-to-day reports for one app keep one filename.
  safe="$(printf '%s' "${ref%%@*}" | tr '/:@' '___')"
  log "Scanning ${ref%%@*} (${image_id:7:12})"
  for fmt in table json; do
    ext="txt"; [[ "$fmt" == "json" ]] && ext="json"
    docker run --rm "${TRIVY_LIMITS[@]}" \
      -v "$CACHE_DIR:/root/.cache/trivy" \
      -v /var/run/docker.sock:/var/run/docker.sock \
      "$TRIVY_IMAGE" image --quiet --no-progress --scanners vuln \
      --severity "$SEVERITY" --format "$fmt" --output /dev/stdout "$image_id" \
      > "$OUT_DIR/trivy-$safe.$ext" 2>/dev/null || true
  done
done

# Aggregate the json: count HIGH/CRITICAL, attribute fixable CRITICALs to
# their image, and age each against the first-seen state file.
summary="$(python3 - "$OUT_DIR" "$FIRST_SEEN" "$GRACE_DAYS" "$DATE_UTC" <<'PY'
import datetime, glob, json, os, sys

out, state_path, grace_days, today_s = (
    sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4])
today = datetime.date.fromisoformat(today_s)

try:
    with open(state_path) as fh:
        state = json.load(fh)
except (OSError, ValueError):
    state = {}

high = crit = 0
fixable = []  # (key, image, description)
for path in sorted(glob.glob(os.path.join(out, "trivy-*.json"))):
    try:
        with open(path) as fh:
            doc = json.load(fh)
    except (ValueError, OSError):
        continue
    meta = doc.get("Metadata") or {}
    refs = meta.get("RepoDigests") or meta.get("RepoTags") or []
    image = refs[0].split("@")[0] if refs else \
        os.path.basename(path)[len("trivy-"):-len(".json")]
    for res in doc.get("Results") or []:
        for v in res.get("Vulnerabilities") or []:
            sev = (v.get("Severity") or "").upper()
            if sev == "HIGH":
                high += 1
            elif sev == "CRITICAL":
                crit += 1
                if v.get("FixedVersion"):
                    key = f"{v.get('VulnerabilityID')}|{v.get('PkgName')}|{image}"
                    fixable.append((key, image, (
                        f"{v.get('VulnerabilityID')} {v.get('PkgName')} "
                        f"{v.get('InstalledVersion')} -> {v.get('FixedVersion')}")))

# Age each finding; keep only findings seen this run in the state so anything
# the pipeline fixed drops out (a re-appearing finding restarts its clock).
new_state, lines, overdue = {}, [], []
for key, image, desc in fixable:
    first = state.get(key, today_s)
    new_state[key] = first
    age = (today - datetime.date.fromisoformat(first)).days
    line = f"[{image}] {desc} (seen {first})"
    lines.append(line)
    if age >= grace_days:
        overdue.append(line)

tmp = state_path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(new_state, fh, indent=0, sort_keys=True)
os.replace(tmp, state_path)

print(f"TOTAL HIGH={high} CRITICAL={crit} "
      f"CRITICAL_FIXABLE={len(fixable)} OVERDUE={len(overdue)}")
for line in lines[:25]:
    print(f"  FIXABLE: {line}")
for line in overdue[:25]:
    print(f"  OVERDUE: {line}")
PY
)"

printf '%s\n' "$summary" | tee "$OUT_DIR/summary.txt"

overdue="$(printf '%s\n' "$summary" | head -n1 | sed -E 's/.*OVERDUE=([0-9]+).*/\1/')"
if [[ "${overdue:-0}" -gt 0 && -x /usr/local/bin/vps-notify ]]; then
  detail="$(printf '%s\n' "$summary" | grep '^  OVERDUE: ' | head -5)"
  /usr/local/bin/vps-notify \
    "Vulnerability scan: ${overdue} fixable CRITICAL CVE(s) past grace" \
    "Fixes have been available for ${GRACE_DAYS}+ days and the update pipeline has NOT cleared them — this needs a human. ${detail}
See ${OUT_DIR}/summary.txt." \
    urgent \
    rotating_light,package
fi

# Prune old reports so evidence accumulates without filling the disk.
find "$STATE_DIR" -mindepth 1 -maxdepth 1 -type d -mtime "+$RETENTION_DAYS" -exec rm -rf {} + 2>/dev/null || true

log "Scan complete — reports in $OUT_DIR"
