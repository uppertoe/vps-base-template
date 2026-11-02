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
# server-files/MANIFEST lists each file and how closely it must match.
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

if (( drift )); then
  if (( fix )); then note "fixed; review 'git diff' and commit."; exit 0; fi
  echo "check-server-files: this repo's shared files differ from the scaffold's canonical set." >&2
  echo "Run: bash scripts/check-server-files.sh --fix   (then review and commit)" >&2
  exit 1
fi
echo "check-server-files: OK (scaffold ${scaffold_commit:0:7})"
