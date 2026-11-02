#!/usr/bin/env bash
# check-image-provenance.sh — surface (and sanity-check) the git commit each
# first-party image was built from.
#
# Why: a container can pass its healthcheck while running STALE code. That bit
# us once — apps/users was pinned to a digest built from an old commit (the
# newer commits were only ever local, so CI never built them), so the deployed
# portal silently lacked its shared-secret gate. Nothing failed; everything was
# "healthy".
#
# This prints, for every pinned ghcr.io/{uppertoe,anaes-data-lab}/* image, the
# revision + commit subject it was built from, whether that commit is the source
# repo's main HEAD, and FAILS if the commit is not in the source repo at all (a
# dangling / mis-pinned digest). It makes "exactly what code is deploying"
# visible on every PR, so a wrong-but-healthy image is caught by eye.
#
# It CANNOT detect a source commit that was never pushed — that is source-repo
# discipline, not something the consuming repo can see. It closes the visibility
# gap, not that specific hole.
set -uo pipefail

summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
fail=0

# First-party namespaces: our own images, gated by their own repo CI.
first_party_re='ghcr\.io/(uppertoe|anaes-data-lab)/'

{
  echo "## Image provenance (first-party)"
  echo ""
  echo "| image | revision | commit | vs source main | in source? |"
  echo "|---|---|---|---|---|"
} >> "$summary"

refs=()
while IFS= read -r r; do
  [[ -n "$r" ]] && refs+=("$r")
done < <(grep -rhoE 'image:[[:space:]]*\S+' apps/*/docker-compose.yml 2>/dev/null \
  | awk '{print $2}' | grep -E "$first_party_re" | sort -u)

if [[ ${#refs[@]} -eq 0 ]]; then
  echo "| _(none pinned)_ | | | | |" >> "$summary"
  echo "No first-party images pinned — nothing to check."
  exit 0
fi

label() { # ref, label-key -> first non-empty value across platforms
  # A multi-platform index exposes .Image as a per-platform map; a plain
  # single-platform manifest exposes one image, so fall back to that form.
  { docker buildx imagetools inspect "$1" \
      --format "{{ range \$p,\$i := .Image }}{{ index \$i.Config.Labels \"$2\" }}{{ \"\n\" }}{{ end }}" 2>/dev/null \
    || docker buildx imagetools inspect "$1" \
      --format "{{ index .Image.Config.Labels \"$2\" }}" 2>/dev/null; } \
    | grep -v '^$' | sort -u | head -1
}

for ref in "${refs[@]}"; do
  name="${ref%@*}"
  rev="$(label "$ref" org.opencontainers.image.revision)"
  src="$(label "$ref" org.opencontainers.image.source)"

  if [[ -z "$rev" ]]; then
    echo "| \`$name\` | — | (no revision label) | — | ⚠️ unverifiable |" >> "$summary"
    echo "WARN: $name carries no revision label — build it with docker/metadata-action so provenance is traceable." >&2
    continue
  fi

  # Derive the source repo from the image PATH (the trust anchor — we only reach
  # this loop for first-party ghcr.io/{uppertoe,anaes-data-lab}/* images). The
  # image's own source label is attacker-influenceable, so only honour it when
  # its owner is still first-party (it can then name the exact repo but can't
  # redirect verification to an external one).
  slug="$(sed -E 's#^ghcr\.io/([^/]+)/([^:@]+).*#\1/\2#' <<<"$name")"
  if [[ "$src" =~ github\.com/([^/]+)/([^/[:space:]]+) ]]; then
    owner="${BASH_REMATCH[1]}"; repo="${BASH_REMATCH[2]%.git}"
    case "$owner" in uppertoe|anaes-data-lab) slug="$owner/$repo" ;; esac
  fi

  short="${rev:0:9}"

  # Is the source repo reachable to us? (public always; private needs a token
  # with cross-repo read — absent that we warn rather than fail.)
  if ! gh api "repos/$slug" --jq .full_name >/dev/null 2>&1; then
    echo "| \`$name\` | \`$short\` | — | — | ⚠️ $slug unreachable |" >> "$summary"
    echo "WARN: cannot reach source repo $slug to verify $name@$short (private / no token?)." >&2
    continue
  fi

  # Verify the revision is a real commit in the source repo. Key off gh's EXIT
  # CODE, not output emptiness: on a 404/422 gh prints the error JSON to stdout
  # (non-empty) and exits non-zero, so an emptiness test would let a dangling
  # pin pass. pipefail propagates gh's status through the `head` pipe.
  if ! subject="$(gh api "repos/$slug/commits/$rev" --jq '.commit.message' 2>/dev/null | head -1)" \
       || [[ -z "$subject" ]]; then
    echo "| \`$name\` | \`$short\` | — | — | ❌ NOT in $slug |" >> "$summary"
    echo "FAIL: $name is pinned to a digest built from $short, which is not a commit in $slug (dangling / mis-pinned)." >&2
    fail=1
    continue
  fi

  # Distance from source main (cosmetic; key off exit code here too).
  vsmain="?"
  if head="$(gh api "repos/$slug/commits/main" --jq '.sha' 2>/dev/null)" && [[ -n "$head" ]]; then
    if [[ "$head" == "$rev" ]]; then
      vsmain="= main HEAD"
    elif ahead="$(gh api "repos/$slug/compare/$rev...main" --jq '.ahead_by' 2>/dev/null)" && [[ -n "$ahead" ]]; then
      vsmain="behind main by $ahead"
    fi
  fi

  subject="${subject//|/\\|}"
  echo "| \`$name\` | \`$short\` | ${subject} | ${vsmain} | ✅ in $slug |" >> "$summary"
  echo "OK: $name ← $short \"$subject\" ($vsmain)"
done

if [[ "$fail" -ne 0 ]]; then
  echo "Image provenance check FAILED — a pinned first-party image was built from a commit that is not in its source repo." >&2
  exit 1
fi
echo "Image provenance check passed."
