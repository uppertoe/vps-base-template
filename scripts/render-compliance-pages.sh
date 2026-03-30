#!/usr/bin/env bash
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

{
  echo "<!doctype html>"
  echo "<html lang=\"en\">"
  echo "<head>"
  echo "  <meta charset=\"utf-8\">"
  echo "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
  echo "  <title>VPS Scaffold Compliance Reports</title>"
  echo "  <style>"
  echo "    body { font-family: sans-serif; margin: 2rem auto; max-width: 60rem; padding: 0 1rem; line-height: 1.5; }"
  echo "    code { background: #f4f4f4; padding: 0.15rem 0.3rem; }"
  echo "    ul { padding-left: 1.25rem; }"
  echo "  </style>"
  echo "</head>"
  echo "<body>"
  echo "  <h1>VPS Scaffold Compliance Reports</h1>"
  echo "  <p>Generated at <code>${timestamp}</code> from commit <code>${commit_sha}</code>.</p>"
  echo "  <p>This CI workflow runs <code>bootstrap.yml</code>, <code>site-first-run.yml</code>, <code>audit-openscap.yml</code>, and <code>audit-docker.yml</code> on a fresh GitHub-hosted Ubuntu 24.04 runner.</p>"
  echo "  <p>The resulting reports are useful as a regression signal for the scaffold. They do not replace auditing a real VPS with the actual downstream app stack.</p>"
  echo "  <h2>Reports</h2>"
  echo "  <ul>"

  if [[ -d "$SITE_ROOT/reports" ]]; then
    while IFS= read -r file; do
      rel_path="${file#"$SITE_ROOT"/}"
      echo "    <li><a href=\"${rel_path}\">${rel_path}</a></li>"
    done < <(find "$SITE_ROOT/reports" -type f | sort)
  else
    echo "    <li>No reports were generated.</li>"
  fi

  echo "  </ul>"
  echo "</body>"
  echo "</html>"
} > "$SITE_ROOT/index.html"
