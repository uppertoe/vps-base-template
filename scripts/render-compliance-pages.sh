#!/usr/bin/env bash
# render-compliance-pages.sh — build the GitHub Pages evidence dashboard from
# the CI audit reports (see .github/workflows/compliance-audits.yml).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SITE_ROOT="${1:-$REPO_ROOT/compliance-site}"

rm -rf "$SITE_ROOT"
mkdir -p "$SITE_ROOT"

if [[ -d "$REPO_ROOT/reports" ]]; then
  cp -R "$REPO_ROOT/reports" "$SITE_ROOT/reports"
fi

timestamp="$(date -u +"%Y-%m-%d %H:%M:%SZ")"
commit_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
commit_short="${commit_sha:0:9}"
repo_url="https://github.com/uppertoe/vps-base-template"

# --- Extract summaries (defensive: every field defaults to n/a) -------------
oscap_l1_xml="$(find "$SITE_ROOT/reports" -name 'results.xml' -path '*openscap*l1*' 2>/dev/null | head -n1 || true)"
[[ -n "$oscap_l1_xml" ]] || oscap_l1_xml="$(find "$SITE_ROOT/reports" -name 'results.xml' -path '*openscap*' -not -path '*l2*' 2>/dev/null | head -n1 || true)"
oscap_l2_xml="$(find "$SITE_ROOT/reports" -name 'results.xml' -path '*openscap*l2*' 2>/dev/null | head -n1 || true)"
bench_log="$(find "$SITE_ROOT/reports" -name 'docker-bench.log' 2>/dev/null | head -n1 || true)"
compose_json="$(find "$SITE_ROOT/reports" -name 'compose-audit.json' 2>/dev/null | head -n1 || true)"
vuln_summary="$(find "$SITE_ROOT/reports" -name 'summary.txt' -path '*vuln*' 2>/dev/null | head -n1 || true)"

oscap_counts() {
  python3 - "$1" <<'PY'
import re, sys
path = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    data = open(path).read()
    from collections import Counter
    c = Counter(re.findall(r"<result>([^<]+)</result>", data))
    print(c.get("pass", 0), c.get("fail", 0), c.get("notselected", 0),
          c.get("notapplicable", 0), c.get("error", 0))
except Exception:
    print("n/a n/a n/a n/a n/a")
PY
}
read -r OS_PASS OS_FAIL OS_NOTSEL OS_NA OS_ERR <<< "$(oscap_counts "$oscap_l1_xml")"
read -r L2_PASS L2_FAIL L2_NOTSEL L2_NA L2_ERR <<< "$(oscap_counts "$oscap_l2_xml")"

read -r CA_PASS CA_WARN CA_EXC <<< "$(python3 - "$compose_json" <<'PY'
import json, sys
try:
    s = json.load(open(sys.argv[1]))["summary"]
    print(s.get("pass", 0), s.get("warn", 0), s.get("excepted", 0))
except Exception:
    print("n/a n/a n/a")
PY
)"

VULN_LINE="n/a"
if [[ -n "$vuln_summary" && -r "$vuln_summary" ]]; then
  VULN_LINE="$(grep -m1 '^TOTAL' "$vuln_summary" || echo n/a)"
fi

BENCH_SCORE="n/a"; BENCH_CHECKS="n/a"
if [[ -n "$bench_log" && -r "$bench_log" ]]; then
  BENCH_SCORE="$(sed -e $'s/\x1b\[[0-9;]*m//g' "$bench_log" | awk -F': ' '/Score:/ {print $2}' | tail -n1)"
  BENCH_CHECKS="$(sed -e $'s/\x1b\[[0-9;]*m//g' "$bench_log" | awk -F': ' '/Checks:/ {print $2}' | tail -n1)"
  BENCH_SCORE="${BENCH_SCORE:-n/a}"
  BENCH_CHECKS="${BENCH_CHECKS:-n/a}"
fi

# --- Grouped report links ----------------------------------------------------
links_for() {
  # links_for <find-pattern> — list matching report files as <li> links
  local pattern="$1" file rel_path found=0
  while IFS= read -r file; do
    rel_path="${file#"$SITE_ROOT"/}"
    echo "      <li><a href=\"${rel_path}\">${rel_path}</a></li>"
    found=1
  done < <(find "$SITE_ROOT/reports" -type f -path "$pattern" 2>/dev/null | sort)
  [[ $found -eq 1 ]] || echo "      <li>none in this run</li>"
}

{
  cat <<HTML
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>VPS Scaffold Compliance Evidence</title>
  <style>
    body { font-family: sans-serif; margin: 2rem auto; max-width: 60rem; padding: 0 1rem; line-height: 1.5; color: #1a1a1a; }
    code { background: #f4f4f4; padding: 0.15rem 0.3rem; border-radius: 3px; }
    ul { padding-left: 1.25rem; }
    .tiles { display: flex; gap: 1rem; flex-wrap: wrap; margin: 1rem 0; }
    .tile { border: 1px solid #ddd; border-radius: 8px; padding: 0.8rem 1.1rem; min-width: 14rem; }
    .tile h3 { margin: 0 0 0.4rem 0; font-size: 0.95rem; }
    .big { font-size: 1.5rem; font-weight: 700; }
    .ok { color: #1a7f37; } .warn { color: #b35900; } .muted { color: #666; }
    .note { background: #f6f8fa; border-left: 4px solid #b9c0c7; padding: 0.6rem 1rem; margin: 1rem 0; }
    h2 { border-bottom: 1px solid #eee; padding-bottom: 0.25rem; margin-top: 2rem; }
    footer { margin-top: 3rem; font-size: 0.85rem; color: #666; }
  </style>
</head>
<body>
  <h1>VPS Scaffold Compliance Evidence</h1>
  <p>Generated <code>${timestamp}</code> from commit
     <a href="${repo_url}/commit/${commit_sha}"><code>${commit_short}</code></a>.
     CI provisions a fresh Ubuntu 24.04 runner with <code>bootstrap.yml</code> +
     <code>site-first-run.yml</code>, boots the server template's compose stack
     (the same digest-pinned images a production instance runs), and audits
     host (CIS L1 + L2, tailored), daemon, running containers and images.</p>

  <div class="tiles">
    <div class="tile">
      <h3>Host OS — CIS L1 Server (OpenSCAP, tailored)</h3>
      <div class="big"><span class="ok">${OS_PASS} pass</span> · <span class="warn">${OS_FAIL} fail</span></div>
      <div class="muted">${OS_NOTSEL} notselected (documented exceptions) ·
        ${OS_NA} n/a · ${OS_ERR} error (manually adjudicated)</div>
    </div>
    <div class="tile">
      <h3>Host OS — CIS L2 Server (deployment target profile)</h3>
      <div class="big"><span class="ok">${L2_PASS} pass</span> · <span class="warn">${L2_FAIL} fail</span></div>
      <div class="muted">${L2_NOTSEL} notselected · ${L2_NA} n/a · ${L2_ERR} error</div>
    </div>
    <div class="tile">
      <h3>Docker daemon — CIS Docker §1–4 (docker-bench)</h3>
      <div class="big">score ${BENCH_SCORE}</div>
      <div class="muted">${BENCH_CHECKS} checks (informational index, not a KPI)</div>
    </div>
    <div class="tile">
      <h3>Running stack — CIS Docker §5 + ISM tier separation</h3>
      <div class="big"><span class="ok">${CA_PASS} pass</span> · <span class="warn">${CA_WARN} warn</span></div>
      <div class="muted">${CA_EXC} excepted · audited against the server template's live compose stack</div>
    </div>
    <div class="tile">
      <h3>Image CVEs — Trivy over the running images</h3>
      <div class="big" style="font-size:1.05rem">${VULN_LINE}</div>
      <div class="muted">report-only; fixable CRITICALs page the operator on real hosts</div>
    </div>
  </div>

  <div class="note">
    <strong>Read the numbers in context.</strong> <em>notselected</em> results are
    deliberate, documented exceptions from the
    <a href="${repo_url}/blob/main/docs/08-security-model.md#exceptions-register">exceptions register</a>
    (encoded in the OpenSCAP tailoring file). CI-runner <em>fail</em>s include
    GitHub-runner-specific deltas (e.g. AppArmor profile enforcement and AIDE
    initialisation are disabled in CI); the authoritative score is a real VPS
    audited via <code>audit-all.yml</code>.
  </div>

  <h2>Host OS (OpenSCAP — L1 and L2 tailored profiles)</h2>
  <ul>
$(links_for '*openscap*')
  </ul>

  <h2>Running stack (compose audit — §5 + data-tier separation)</h2>
  <ul>
$(links_for '*compose-audit*')
  </ul>

  <h2>Image CVEs (Trivy)</h2>
  <ul>
$(links_for '*vuln*')
  </ul>

  <h2>Docker daemon (docker-bench)</h2>
  <ul>
$(links_for '*docker-bench*')
  </ul>

  <h2>Runner diagnostics</h2>
  <ul>
$(links_for '*ci-diagnostics*')
  </ul>

  <h2>What CI does — and does not — prove</h2>
  <p>This page is a <strong>regression signal for the scaffold</strong>: the same
     hardening code, applied to a clean machine, audited on every change to
     <code>main</code> and weekly. It does not audit a production VPS. The
     controls that only exist on a long-lived host are audited on-VPS with
     <code>audit-all.yml</code> (see
     <a href="${repo_url}/blob/main/docs/06-auditing.md">docs/06-auditing.md</a>):
     AIDE integrity over time, backup restore drills (RPO/RTO), off-host
     log-export chains, and the per-instance apps beyond the bundled stack.
     Production audit bundles are deliberately <strong>not</strong> published
     here — instance evidence is private to the audit pack.</p>
  <ul>
    <li><a href="${repo_url}/blob/main/docs/08-security-model.md">Security model &amp; exceptions register</a></li>
    <li><a href="${repo_url}/blob/main/docs/compliance-plan-vic-health.md">Victorian health compliance plan</a></li>
    <li><a href="${repo_url}/tree/main/docs/templates">Evidence pack templates (SSP, control matrix, …)</a></li>
  </ul>

  <footer>vps-base-template · generated by scripts/render-compliance-pages.sh</footer>
</body>
</html>
HTML
} > "$SITE_ROOT/index.html"
