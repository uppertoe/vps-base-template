#!/usr/bin/env bash
# check-update-pipeline.sh — verify the hands-off update pipeline against the
# recorded intended state (scripts/update-pipeline-state.json).
#
# The pipeline's moving parts live OUTSIDE this repo (Renovate app installs,
# Mend org settings, per-app-repo workflows), so like check-digest-freshness
# this script asserts observable reality instead: for every fleet repo it
# checks (a) a Renovate config file exists, (b) no GitHub workflow has been
# auto-disabled (schedules die silently after ~60 days of repo inactivity —
# the weekly image rebuilds' known failure mode), and (c) Renovate's
# Dependency Dashboard issue has been touched recently (the bot updates it on
# every run, making it a heartbeat for "the app is installed, enabled and not
# in Silent mode").
#
# Auth: uses `gh` — locally your login sees everything. In CI, GITHUB_TOKEN
# only reads THIS repo and public repos; the workflow makes it authoritative
# by minting per-owner tokens from the fleet GitHub App and exporting them as
# FLEET_READ_TOKEN_<OWNER> ('-' -> '_', uppercased), with FLEET_READ_TOKEN
# then the ambient gh auth as fallbacks.
set -euo pipefail

# The server repo root: this file is installed at <server>/scaffold/scripts/server/,
# so three levels up, unless the calling shim says otherwise.
ROOT_DIR="${SERVER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
STATE_FILE="$ROOT_DIR/scripts/update-pipeline-state.json"

# Run gh with the token that can see this repo. The server repo always uses
# the ambient auth (in CI that's GITHUB_TOKEN, which reads it natively — an
# owner token scoped to only the private fleet repos would 404 on it).
gh_fleet() {
  local repo="$1"; shift
  if [[ "$repo" != "$SERVER_REPO" ]]; then
    local owner_var
    owner_var="FLEET_READ_TOKEN_$(printf '%s' "${repo%%/*}" | tr '[:lower:]-' '[:upper:]_' | tr -cd 'A-Z0-9_')"
    local tok="${!owner_var:-${FLEET_READ_TOKEN:-}}"
    if [[ -n "$tok" ]]; then
      GH_TOKEN="$tok" gh "$@"
      return
    fi
  fi
  gh "$@"
}

read_state() { python3 -c "
import json,sys
s=json.load(open('$STATE_FILE'))
print(s['$1'])"; }

SERVER_REPO="$(read_state server_repo)"
max_days="$(read_state max_days_since_renovate_activity)"
renovate_bots="$(python3 -c "
import json
for b in json.load(open('$STATE_FILE'))['renovate_bots']: print(b)")"
repos="$(python3 -c "
import json
s=json.load(open('$STATE_FILE'))
for r in s['app_repos']: print(r['repo'])
print(s['server_repo'])")"

drift=0
warn=0

for repo in $repos; do
  # (a) Renovate config present. gh api exits identically for "404 file
  # missing" and transient errors (rate limit, 5xx, network), so classify by
  # the error body — only a real Not Found on both filenames is drift
  # (GitHub also 404s unreadable private repos, which stays the SKIP path via
  # the repo probe). Anything else is a transient: warn, don't page.
  cfg="MISSING"
  for f in renovate.json renovate.json5; do
    if out="$(gh_fleet "$repo" api "repos/$repo/contents/$f" --jq .name 2>&1)"; then
      cfg="FOUND"
      break
    fi
    printf '%s' "$out" | grep -q "Not Found" || cfg="ERROR"
  done
  if [[ "$cfg" == "ERROR" ]]; then
    echo "SKIP   $repo: transient API error reading repo contents"
    warn=1
    continue
  elif [[ "$cfg" == "MISSING" ]]; then
    if gh_fleet "$repo" api "repos/$repo" --jq .name >/dev/null 2>&1; then
      echo "DRIFT  $repo: no renovate.json(5) at repo root"
      drift=1
    else
      echo "SKIP   $repo: not readable with this token (set FLEET_READ_TOKEN_* for full coverage)"
      warn=1
      continue
    fi
  fi

  # (b) no auto-disabled workflows (60-day inactivity kill switch).
  # gh api prints the error BODY to stdout on an HTTP error, so gate on the
  # exit status — otherwise a 403 JSON blob reads as a "disabled workflow".
  if disabled="$(gh_fleet "$repo" api "repos/$repo/actions/workflows" \
      --jq '.workflows[] | select(.state != "active") | "\(.name) (\(.state))"' 2>/dev/null)"; then
    if [[ -n "$disabled" ]]; then
      echo "DRIFT  $repo: workflow not active: $disabled"
      drift=1
    fi
  else
    echo "SKIP   $repo: cannot list workflows with this token"
    warn=1
  fi

  # (c) Renovate heartbeat: Dependency Dashboard updated recently. Both bot
  # identities count — dashboards created by Mend keep renovate[bot] as their
  # immutable creator even after the self-hosted runner takes them over, while
  # fresh repos get uppertoe-fleet-bot[bot] ones (see renovate_bots in the
  # state file).
  updated=""
  for bot in $renovate_bots; do
    enc="${bot//\[/%5B}"; enc="${enc//\]/%5D}"
    u="$(gh_fleet "$repo" api "repos/$repo/issues?creator=${enc}&state=open&per_page=10" \
      --jq '[.[] | select(.title | test("Dependency Dashboard"))][0].updated_at // empty' 2>/dev/null || true)"
    [[ -n "$u" && ( -z "$updated" || "$u" > "$updated" ) ]] && updated="$u"
  done
  if [[ -z "$updated" ]]; then
    # Fall back to the most recent bot PR of any state.
    for bot in $renovate_bots; do
      u="$(gh_fleet "$repo" pr list -R "$repo" --state all -L 1 \
        --search "author:app/${bot%\[bot\]}" --json createdAt \
        --jq '.[0].createdAt // empty' 2>/dev/null || true)"
      [[ -n "$u" && ( -z "$updated" || "$u" > "$updated" ) ]] && updated="$u"
    done
  fi
  if [[ -z "$updated" ]]; then
    echo "DRIFT  $repo: no Renovate dashboard or PRs found — app not installed, repo not selected, or Silent mode"
    drift=1
  else
    age_days="$(python3 -c "
from datetime import datetime,timezone
d=datetime.fromisoformat('${updated}'.replace('Z','+00:00'))
print((datetime.now(timezone.utc)-d).days)")"
    if (( age_days > max_days )); then
      echo "DRIFT  $repo: last Renovate activity ${age_days}d ago (max ${max_days}d)"
      drift=1
    else
      echo "OK     $repo: renovate active ${age_days}d ago"
    fi
  fi
done

# The ghcr hostRule (private image digest lookups) lives in the self-hosted
# runner's global config — assert it still references the registry secret.
runner_repo="$(read_state renovate_runner_repo)"
if cfg_js="$(gh_fleet "$runner_repo" api "repos/$runner_repo/contents/config.js" --jq .content 2>/dev/null)"; then
  if ! printf '%s' "$cfg_js" | base64 -d 2>/dev/null | grep -q "GHCR_READ_TOKEN"; then
    echo "DRIFT  renovate-runner: config.js no longer references GHCR_READ_TOKEN"
    drift=1
  fi
else
  echo "SKIP   renovate-runner: cannot read config.js with this token"
  warn=1
fi

if (( drift )); then
  echo "RESULT: drift detected — compare with scripts/update-pipeline-state.json"
  exit 1
fi
(( warn )) && echo "RESULT: ok (some repos unverifiable with this token)"
exit 0
