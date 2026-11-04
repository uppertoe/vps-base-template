#!/usr/bin/env bash
# CI guard for a server repo's secrets (docs/13-secrets.md). Run from the server
# repo root: bash scaffold/docker/check-secrets-encrypted.sh
#
# Fails when:
#   - secrets/ exists but .sops.yaml (the recipients for each file) does not;
#   - a file under secrets/ is not README.md and is not a *.sops file;
#   - a *.env.sops file (and secrets/recovery.sops) is not a SOPS-encrypted
#     dotenv file in which every non-empty line is an encrypted value
#     (KEY=ENC[...]), an encrypted comment (#ENC[...]), an empty value (KEY=),
#     or SOPS' own age metadata. Anything else could be plaintext. YAML and
#     JSON are refused there, since the deploy step reads dotenv only;
#   - any other *.sops file (a whole file, docs/13 "Whole files") is not the
#     JSON document SOPS writes for a binary-type file, with its one data
#     value encrypted and age as the only key source; or it sits anywhere but
#     below a subdirectory of an app; or git tracks the file it would be
#     rendered to, which the render would silently replace;
#   - git tracks a plain env file (.env, *.env, .env.*) other than an *.example.
set -euo pipefail

fail=0
say() { echo "check-secrets-encrypted: $*" >&2; fail=1; }

# Keep in step with ALLOWED_METADATA in ansible/roles/deploy-user/files/vps-secrets-render.
meta='sops_(age__list_[0-9]+__map_(recipient|enc)|mac|lastmodified|version|unencrypted_suffix|encrypted_suffix|unencrypted_regex|encrypted_regex|unencrypted_comment_regex|encrypted_comment_regex|mac_only_encrypted|shamir_threshold)='
# An empty comment line ("#" alone, or "#" and spaces) is left unencrypted by
# SOPS and carries nothing; a comment with content must be encrypted.
ok_line="^([^=#[:space:]][^=[:space:]]*=ENC\\[AES256_GCM,.*\\]|#ENC\\[AES256_GCM,.*\\]|#[[:space:]]*|[^=#[:space:]][^=[:space:]]*=|${meta}.*)\$"
# Keep in step with FILE_TARGET in vps-secrets-render: a whole file is rendered
# only below a subdirectory of an app.
name='[A-Za-z0-9_][A-Za-z0-9._-]*'
whole_path="^secrets/apps/${name}/(${name}/)+${name}\\.sops\$"

# The document sops writes for a binary-type file: exactly "data" and "sops",
# the data encrypted, a mac present, and no key source other than age. Keep
# in step with FILE_METADATA_ALLOWED in vps-secrets-render. Prints the reason
# on stdout and exits 1 when the file fails.
check_whole_file() {
  python3 - "$1" <<'PY'
import json, sys
allowed = {"age", "mac", "lastmodified", "version", "unencrypted_suffix", "encrypted_suffix",
           "unencrypted_regex", "encrypted_regex", "unencrypted_comment_regex",
           "encrypted_comment_regex", "mac_only_encrypted", "shamir_threshold"}
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        doc = json.load(fh)
except (OSError, ValueError, UnicodeDecodeError):
    print("is not the JSON document SOPS writes for a binary-type file"); sys.exit(1)
if not isinstance(doc, dict) or set(doc) != {"data", "sops"} or not isinstance(doc["sops"], dict):
    print("is not the JSON document SOPS writes for a binary-type file (data and sops only)"); sys.exit(1)
if not isinstance(doc["data"], str) or not doc["data"].startswith("ENC[AES256_GCM,"):
    print("holds content that is not encrypted"); sys.exit(1)
if "mac" not in doc["sops"]:
    print("has no mac in its SOPS metadata"); sys.exit(1)
bad = sorted(set(doc["sops"]) - allowed)
if bad:
    print("names a key source other than age (" + ", ".join(bad) + ")"); sys.exit(1)
PY
}

if [[ -d secrets ]]; then
  [[ -f .sops.yaml ]] || say "secrets/ exists but .sops.yaml does not"
  while IFS= read -r -d '' f; do
    case "$f" in
      secrets/README.md) continue ;;
      *.env.sops|secrets/recovery.sops) ;;
      *.sops)
        if ! [[ "$f" =~ $whole_path ]]; then
          say "$f would be rendered outside an app's own subdirectory (apps/<app>/<dir>/<file>), the only place a whole file is written"
          continue
        fi
        target="${f#secrets/}"; target="${target%.sops}"
        if git ls-files --error-unmatch -- "$target" >/dev/null 2>&1; then
          say "$f would be rendered over $target, which git tracks; a rendered file never replaces a reviewed one"
        fi
        if ! reason="$(check_whole_file "$f")"; then
          say "$f $reason"
        fi
        continue ;;
      *) say "$f is not a .sops file"; continue ;;
    esac
    if ! grep -qE '^sops_mac=ENC\[' "$f"; then
      say "$f is not a SOPS-encrypted dotenv file (no sops_mac line)"
      continue
    fi
    bad="$(grep -nvE "$ok_line" "$f" | grep -vE '^[0-9]+:[[:space:]]*$' | cut -d: -f1 | head -5 | paste -sd, - || true)"
    if [[ -n "$bad" ]]; then
      say "$f has lines that are neither encrypted nor SOPS metadata (line ${bad}); values are not shown"
    fi
  done < <(git ls-files -z secrets)
fi

while IFS= read -r -d '' f; do
  case "$f" in
    *.example) continue ;;
    secrets/*.sops) continue ;;  # the encrypted files themselves, checked above
  esac
  say "$f is a tracked env file; secrets belong in secrets/*.sops"
done < <(git ls-files -z -- '.env' '*.env' '*/.env' '.env.*' '*/.env.*')

if [[ $fail -ne 0 ]]; then
  exit 1
fi
echo "check-secrets-encrypted: OK"
