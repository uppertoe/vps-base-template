#!/usr/bin/env bash
# =============================================================================
# vuln-scan.sh — Scan the RUNNING container images for CVEs with Trivy.
# =============================================================================
#
# Installed by the vuln-scan Ansible role and run daily by vuln-scan.timer.
# Same scan model as ansible/audit-vuln.yml, but on-host and scheduled: dated
# reports accumulate under $STATE_DIR as patch-SLA evidence, and a fixable
# CRITICAL pushes an urgent alert via vps-notify (no-op until configured).
#
# Report-only by design: findings never block anything. The script exits
# non-zero only when the scan itself could not run (Docker down, Trivy pull
# failed), which fires the unit's OnFailure=notify@ hook.
#
# Configuration comes from the systemd unit (Environment=) or the shell:
#   TRIVY_IMAGE, SEVERITY, CACHE_DIR, STATE_DIR, RETENTION_DAYS
# =============================================================================

set -euo pipefail

TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy:0.59.1}"
SEVERITY="${SEVERITY:-HIGH,CRITICAL}"
CACHE_DIR="${CACHE_DIR:-/var/cache/trivy}"
STATE_DIR="${STATE_DIR:-/var/lib/vuln-scan}"
RETENTION_DAYS="${RETENTION_DAYS:-400}"

DATE_UTC="$(date -u +%F)"
OUT_DIR="$STATE_DIR/$DATE_UTC"

log() { echo "[$(date -u +%H:%M:%SZ)] $*"; }

mkdir -p "$CACHE_DIR" "$OUT_DIR"
chmod 750 "$STATE_DIR" "$OUT_DIR"

# Distinct images backing the running containers (skip the trivy image itself).
mapfile -t images < <(docker ps --format '{{.Image}}' | sort -u | grep -v -F "$TRIVY_IMAGE" || true)
if [[ ${#images[@]} -eq 0 ]]; then
  log "No running containers found — nothing to scan."
  echo "TOTAL HIGH=0 CRITICAL=0 CRITICAL_FIXABLE=0 (no running containers)" > "$OUT_DIR/summary.txt"
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
for img in "${images[@]}"; do
  safe="$(printf '%s' "$img" | tr '/:@' '___')"
  log "Scanning $img"
  docker run --rm "${TRIVY_LIMITS[@]}" \
    -v "$CACHE_DIR:/root/.cache/trivy" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    "$TRIVY_IMAGE" image --quiet --no-progress --scanners vuln \
    --severity "$SEVERITY" --format table --output /dev/stdout "$img" \
    > "$OUT_DIR/trivy-$safe.txt" 2>/dev/null || true
  docker run --rm "${TRIVY_LIMITS[@]}" \
    -v "$CACHE_DIR:/root/.cache/trivy" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    "$TRIVY_IMAGE" image --quiet --no-progress --scanners vuln \
    --severity "$SEVERITY" --format json --output /dev/stdout "$img" \
    > "$OUT_DIR/trivy-$safe.json" 2>/dev/null || true
done

# Aggregate the json: count HIGH/CRITICAL and fixable CRITICALs across images.
summary="$(python3 - "$OUT_DIR" <<'PY'
import glob, json, os, sys
out = sys.argv[1]
high = crit = crit_fixable = 0
fixable = []
for path in sorted(glob.glob(os.path.join(out, "trivy-*.json"))):
    try:
        with open(path) as fh:
            doc = json.load(fh)
    except (ValueError, OSError):
        continue
    for res in doc.get("Results") or []:
        for v in res.get("Vulnerabilities") or []:
            sev = (v.get("Severity") or "").upper()
            if sev == "HIGH":
                high += 1
            elif sev == "CRITICAL":
                crit += 1
                if v.get("FixedVersion"):
                    crit_fixable += 1
                    fixable.append(
                        f"{v.get('VulnerabilityID')} {v.get('PkgName')} "
                        f"{v.get('InstalledVersion')} -> {v.get('FixedVersion')}"
                    )
print(f"TOTAL HIGH={high} CRITICAL={crit} CRITICAL_FIXABLE={crit_fixable}")
for line in fixable[:25]:
    print(f"  FIXABLE: {line}")
PY
)"

printf '%s\n' "$summary" | tee "$OUT_DIR/summary.txt"

crit_fixable="$(printf '%s\n' "$summary" | head -n1 | sed -E 's/.*CRITICAL_FIXABLE=([0-9]+).*/\1/')"
if [[ "${crit_fixable:-0}" -gt 0 && -x /usr/local/bin/vps-notify ]]; then
  /usr/local/bin/vps-notify \
    "Vulnerability scan: ${crit_fixable} fixable CRITICAL CVE(s)" \
    "Trivy found ${crit_fixable} CRITICAL CVE(s) with an available fix in the running images. The 48-hour patch clock is running — see ${OUT_DIR}/summary.txt and update the affected images." \
    urgent \
    rotating_light,package
fi

# Prune old reports so evidence accumulates without filling the disk.
find "$STATE_DIR" -mindepth 1 -maxdepth 1 -type d -mtime "+$RETENTION_DAYS" -exec rm -rf {} + 2>/dev/null || true

log "Scan complete — reports in $OUT_DIR"
