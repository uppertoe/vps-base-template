#!/usr/bin/env bash
# CI guard for a server repo's secrets (docs/13-secrets.md). Run from the server
# repo root: bash scaffold/docker/check-secrets-encrypted.sh
#
# Fails when:
#   - a file under secrets/ is not README.md and is not SOPS-encrypted (a *.sops
#     file carrying SOPS metadata);
#   - secrets/ exists but .sops.yaml (the recipients for each file) does not;
#   - git tracks a plain env file (.env, *.env) other than an *.example, which
#     would put a secret in the repo unencrypted.
set -euo pipefail

fail=0
say() { echo "check-secrets-encrypted: $*" >&2; fail=1; }

if [[ -d secrets ]]; then
  [[ -f .sops.yaml ]] || say "secrets/ exists but .sops.yaml does not"
  while IFS= read -r -d '' f; do
    case "$f" in
      secrets/README.md) continue ;;
      *.sops) ;;
      *) say "$f is not a .sops file"; continue ;;
    esac
    # dotenv files carry sops_mac=ENC[...]; YAML and JSON carry a top-level sops key.
    if ! grep -qE '^sops_mac=ENC\[|^sops:|"sops":[[:space:]]*\{' "$f"; then
      say "$f has no SOPS metadata, so it is not encrypted"
    elif grep -qE '^[A-Za-z_][A-Za-z0-9_]*=' "$f" && grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$f" | grep -vqE '^[A-Za-z_][A-Za-z0-9_]*=(ENC\[|$)|^sops_'; then
      say "$f has a value that is not encrypted"
    fi
  done < <(git ls-files -z secrets)
fi

while IFS= read -r -d '' f; do
  case "$f" in
    *.example) continue ;;
  esac
  say "$f is a tracked env file; secrets belong in secrets/*.sops"
done < <(git ls-files -z -- '.env' '*.env' '*/.env')

if [[ $fail -ne 0 ]]; then
  exit 1
fi
echo "check-secrets-encrypted: OK"
