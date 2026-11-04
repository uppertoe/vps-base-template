#!/usr/bin/env bash
# check-server-files.sh -- keep a server repo's copies of the shared files in
# step with the scaffold's canonical set (scaffold/server-files/).
#
# The scaffold is a submodule, so everything under scaffold/ follows the
# pointer by itself. A few files cannot live there: GitHub reads workflows only
# from the repository's own .github/, and the scripts/ shims give operators the
# same `bash scripts/<name>` commands on every server. This check compares
# those copies with the canonical set and fails CI on drift, so a pointer bump
# carries the tooling to every server.
#
#   bash scripts/check-server-files.sh          report drift, exit 1 if any
#   bash scripts/check-server-files.sh --fix    write the canonical copies
#
# server-files/MANIFEST lists each file and how closely it must match. Beyond
# the manifest, the check holds three things --fix cannot write for a server
# (2026-11-03 review, B-M7): the .gitignore must still ignore the secret paths
# after any lines the server adds below the canonical block; a workflow the
# manifest does not name is listed, and refused if it runs on
# pull_request_target; and .scaffold-server.yml must carry only the known
# keys with values the shared CI can act on, since a value it cannot read
# would silently turn a check off.
#
# The shared CI runs this script from the scaffold submodule directly, not
# through the server's scripts/ shim, so the shim is compared and never
# executed before it has been checked.
set -euo pipefail

ROOT_DIR="${SERVER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
CANON="$ROOT_DIR/scaffold/server-files"
MANIFEST="$CANON/MANIFEST"
fix=0; [[ "${1:-}" == "--fix" ]] && fix=1

[[ -f "$MANIFEST" ]] || { echo "check-server-files: $MANIFEST not found; is the scaffold submodule checked out?" >&2; exit 2; }
scaffold_commit="$(git -C "$ROOT_DIR/scaffold" rev-parse HEAD 2>/dev/null || true)"
[[ -n "$scaffold_commit" ]] || { echo "check-server-files: cannot read the scaffold submodule commit" >&2; exit 2; }

drift=0
note() { echo "check-server-files: $*"; }

# The canonical workflow callers reference the scaffold at a placeholder; the
# server copy must reference the commit its submodule is at.
render_ref() { sed "s#uppertoe/vps-base-template/\(.*\)@SCAFFOLD_COMMIT#uppertoe/vps-base-template/\1@${scaffold_commit}#" "$1"; }

while read -r kind path; do
  [[ -z "$kind" || "$kind" == \#* ]] && continue
  src="$CANON/$path"; dst="$ROOT_DIR/$path"
  [[ -f "$src" ]] || { note "manifest names $path but the canonical copy is missing"; drift=1; continue; }
  case "$kind" in
    exact|optional)
      if [[ ! -f "$dst" ]]; then
        [[ "$kind" == optional ]] && continue
        note "missing: $path"; drift=1
        (( fix )) && { mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"; note "  written"; }
      elif ! cmp -s "$src" "$dst"; then
        note "differs: $path"; drift=1
        (( fix )) && { cp "$src" "$dst"; note "  written"; }
      fi
      ;;
    ref)
      want="$(render_ref "$src")"
      if [[ ! -f "$dst" ]] || [[ "$(cat "$dst")" != "$want" ]]; then
        if [[ -f "$dst" ]] && grep -q 'uppertoe/vps-base-template/.*@[0-9a-f]\{40\}' "$dst" \
           && ! grep -q "@${scaffold_commit}" "$dst"; then
          note "differs: $path (its scaffold ref is not the submodule commit ${scaffold_commit:0:7})"
        else
          note "differs: $path"
        fi
        drift=1
        (( fix )) && { mkdir -p "$(dirname "$dst")"; printf '%s\n' "$want" > "$dst"; note "  written"; }
      fi
      ;;
    block)
      if [[ ! -f "$dst" ]]; then
        note "missing: $path"; drift=1
        (( fix )) && { cp "$src" "$dst"; note "  written"; }
      elif ! python3 - "$src" "$dst" <<'PY'
import sys
canon, dst = open(sys.argv[1]).read(), open(sys.argv[2]).read()
sys.exit(0 if canon.strip("\n") in dst else 1)
PY
      then
        note "differs: $path (the canonical block is not present verbatim)"; drift=1
        (( fix )) && { { cat "$src"; echo; echo "# --- lines below are this server's own ---"; cat "$dst"; } > "$dst.new" && mv "$dst.new" "$dst"; note "  canonical block prepended; review the merged file"; }
      fi
      # The block being present is not the same as the block holding: a later
      # line such as "!.env" un-ignores what it ignores. Ask git whether the
      # paths the block exists for are still ignored, with the operator's own
      # global excludes set aside so the answer is the repository's alone.
      if [[ "$path" == .gitignore && -f "$dst" ]]; then
        for canary in .env apps/x/.env apps/x/db/.env backup/config.env backup/services/x.env \
                      recovery-bundle-x.tar.gz.enc .recovery-bundle-last docker-compose.override.yml ansible/hosts; do
          if ! git -C "$ROOT_DIR" -c core.excludesFile=/dev/null check-ignore -q --no-index -- "$canary"; then
            note "differs: $path ($canary is not ignored; a line below the canonical block un-ignores it, and --fix cannot remove that line)"; drift=1
          fi
        done
      fi
      ;;
    seed)
      if [[ ! -f "$dst" ]]; then
        note "missing: $path (seed)"; drift=1
        (( fix )) && { cp "$src" "$dst"; note "  seeded; edit it for this server"; }
      fi
      ;;
    *) note "unknown kind '$kind' in MANIFEST"; drift=1 ;;
  esac
done < "$MANIFEST"

# Shims must stay executable, or `scripts/<name>` stops working for operators.
for f in "$ROOT_DIR"/scripts/*.sh "$ROOT_DIR"/scripts/*.py; do
  [[ -f "$f" ]] || continue
  grep -q 'canonical copy lives in the scaffold' "$f" || continue
  if [[ ! -x "$f" ]]; then note "not executable: ${f#"$ROOT_DIR"/}"; drift=1; (( fix )) && chmod +x "$f"; fi
done

# A workflow the manifest does not name is this server's own. It is listed,
# with any write permission it asks for, so a reviewer sees it beside the
# scaffold's set; one that runs on pull_request_target (pull-request code
# with the base branch's secrets and permissions) is refused, since nothing
# in the estate needs that trigger.
manifest_paths="$(awk '$1 !~ /^#/ && NF == 2 {print $2}' "$MANIFEST")"
for wf in "$ROOT_DIR"/.github/workflows/*.yml "$ROOT_DIR"/.github/workflows/*.yaml; do
  [[ -f "$wf" ]] || continue
  rel="${wf#"$ROOT_DIR"/}"
  grep -qxF -- "$rel" <<<"$manifest_paths" && continue
  if grep -qE '^[^#]*\bpull_request_target\b' "$wf"; then
    note "refused: $rel is not in the scaffold's manifest and runs on pull_request_target"; drift=1
    continue
  fi
  writes="$(grep -oE '^[[:space:]]*[a-z-]+:[[:space:]]*write(-all)?' "$wf" | sed -E 's/^[[:space:]]+//' | sort -u | paste -sd, - || true)"
  note "note: $rel is this server's own workflow (not in the scaffold's manifest)${writes:+; it asks for: $writes}"
done

# .scaffold-server.yml is seeded once and then the server's own, so its
# content is not compared, but the shared CI reads it with a plain parser
# and acts only on exact values: "secrets_sops: yes" would turn the SOPS
# check off without a word. Refuse anything the CI would not act on.
cfg="$ROOT_DIR/.scaffold-server.yml"
if [[ -f "$cfg" ]]; then
  if ! cfg_errors="$(python3 - "$cfg" <<'PY'
import re, sys
booleans = ("gateway_chain", "image_provenance", "secrets_sops")
known = set(booleans) | {"gateway_ref"}
values, errors = {}, []
for n, raw in enumerate(open(sys.argv[1]), 1):
    line = raw.split("#", 1)[0].rstrip()
    if not line.strip():
        continue
    m = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*):\s*(.*?)\s*", line)
    if not m:
        errors.append(f"line {n}: not a 'key: value' line")
        continue
    key, value = m.group(1), m.group(2).strip("'\"")
    if key not in known:
        errors.append(f"line {n}: unknown key '{key}' (known: {', '.join(sorted(known))})")
        continue
    if key in values:
        errors.append(f"line {n}: '{key}' is set twice")
    values[key] = value
    if key in booleans and value not in ("true", "false"):
        errors.append(f"line {n}: '{key}' must be exactly true or false, not '{value}'")
    if key == "gateway_ref" and value and not re.fullmatch(r"[0-9a-f]{40}", value):
        errors.append(f"line {n}: gateway_ref must be a 40-character commit hash, not '{value}'")
if values.get("gateway_chain") == "true" and not values.get("gateway_ref"):
    errors.append("gateway_chain is true but gateway_ref names no commit; the suite would run from a moving branch")
print("\n".join(errors))
sys.exit(1 if errors else 0)
PY
  )"; then
    while IFS= read -r line; do note "invalid: .scaffold-server.yml: $line"; done <<<"$cfg_errors"
    note "  (--fix does not edit this file; correct it by hand)"
    drift=1
  fi
fi

if (( drift )); then
  if (( fix )); then note "fixed; review 'git diff' and commit."; exit 0; fi
  echo "check-server-files: this repo's shared files differ from the scaffold's canonical set." >&2
  echo "Run: bash scripts/check-server-files.sh --fix   (then review and commit)" >&2
  exit 1
fi
echo "check-server-files: OK (scaffold ${scaffold_commit:0:7})"
