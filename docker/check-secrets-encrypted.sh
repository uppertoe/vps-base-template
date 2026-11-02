#!/usr/bin/env bash
# CI guard for a server repo's secrets (docs/13-secrets.md). Run from the server
# repo root: bash scaffold/docker/check-secrets-encrypted.sh
#
# Fails when:
#   - secrets/ exists but .sops.yaml (the recipients for each file) does not;
#   - a file under secrets/ is not README.md and is not a *.sops file;
#   - a *.sops file is not a SOPS-encrypted dotenv file in which every
#     non-empty line is an encrypted value (KEY=ENC[...]), an encrypted comment
#     (#ENC[...]), an empty value (KEY=), or SOPS' own age metadata. Anything
#     else could be plaintext. YAML and JSON are refused, since the deploy step
#     reads dotenv only;
#   - git tracks a plain env file (.env, *.env, .env.*) other than an *.example.
set -euo pipefail

fail=0
say() { echo "check-secrets-encrypted: $*" >&2; fail=1; }

# Keep in step with ALLOWED_METADATA in ansible/roles/deploy-user/files/vps-secrets-render.
meta='sops_(age__list_[0-9]+__map_(recipient|enc)|mac|lastmodified|version|unencrypted_suffix|encrypted_suffix|unencrypted_regex|encrypted_regex|unencrypted_comment_regex|encrypted_comment_regex|mac_only_encrypted|shamir_threshold)='
ok_line="^([^=#[:space:]][^=[:space:]]*=ENC\\[AES256_GCM,.*\\]|#ENC\\[AES256_GCM,.*\\]|[^=#[:space:]][^=[:space:]]*=|${meta}.*)\$"

if [[ -d secrets ]]; then
  [[ -f .sops.yaml ]] || say "secrets/ exists but .sops.yaml does not"
  while IFS= read -r -d '' f; do
    case "$f" in
      secrets/README.md) continue ;;
      *.sops) ;;
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
