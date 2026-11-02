#!/usr/bin/env bash
# Offline checks for docker/check-secrets-encrypted.sh, run by CI's lint job
# and by hand:
#
#   bash docker/tests/test-check-secrets-encrypted.sh
#
# Each case builds a throwaway git repo and expects the check to pass or fail.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
check="$here/check-secrets-encrypted.sh"
failures=0

enc_line='SECRET_KEY=ENC[AES256_GCM,data:abc=,iv:def=,tag:ghi=,type:str]'
meta='sops_mac=ENC[AES256_GCM,data:xyz=,iv:a=,tag:b=,type:str]
sops_version=3.13.3'

case_repo() {
  local dir; dir="$(mktemp -d)"
  git -C "$dir" init -q
  echo "$dir"
}

expect() { # expect pass|fail <name> <dir>
  local want="$1" name="$2" dir="$3" got
  git -C "$dir" add -A >/dev/null 2>&1 || true
  if (cd "$dir" && bash "$check" >/dev/null 2>&1); then got=pass; else got=fail; fi
  if [[ "$got" != "$want" ]]; then
    echo "FAIL: $name (expected $want, got $got)"
    failures=$((failures + 1))
  else
    echo "ok: $name"
  fi
  rm -rf "$dir"
}

d="$(case_repo)"; echo x > "$d/README.md"
expect pass "no secrets directory" "$d"

d="$(case_repo)"; mkdir -p "$d/secrets/apps/planka"; touch "$d/.sops.yaml"
printf '%s\n%s\n' "$enc_line" "$meta" > "$d/secrets/apps/planka/.env.sops"
expect pass "an encrypted dotenv file" "$d"

d="$(case_repo)"; mkdir -p "$d/secrets"
printf '%s\n%s\n' "$enc_line" "$meta" > "$d/secrets/.env.sops"
expect fail "secrets without .sops.yaml" "$d"

d="$(case_repo)"; mkdir -p "$d/secrets"; touch "$d/.sops.yaml"
printf 'SECRET_KEY=plaintext\n' > "$d/secrets/.env.sops"
expect fail "a .sops file with no metadata" "$d"

d="$(case_repo)"; mkdir -p "$d/secrets"; touch "$d/.sops.yaml"
printf '%s\nDB_PASSWORD=plaintext\n%s\n' "$enc_line" "$meta" > "$d/secrets/.env.sops"
expect fail "a plaintext value beside encrypted ones" "$d"

d="$(case_repo)"; mkdir -p "$d/secrets"; touch "$d/.sops.yaml"
printf 'SECRET_KEY=plaintext\n' > "$d/secrets/.env"
expect fail "a plain file under secrets/" "$d"

d="$(case_repo)"; mkdir -p "$d/secrets"; touch "$d/.sops.yaml"
printf 'Notes for operators\n' > "$d/secrets/README.md"
expect pass "a README under secrets/" "$d"

d="$(case_repo)"; mkdir -p "$d/secrets"; touch "$d/.sops.yaml"
printf 'sops:\n    age: []\n    mac: ENC[x]\nkey: ENC[y]\n' > "$d/secrets/recovery.sops"
expect pass "an encrypted YAML file" "$d"

d="$(case_repo)"; mkdir -p "$d/apps/x"; printf 'SECRET=1\n' > "$d/apps/x/.env"
git -C "$d" add -f apps/x/.env
expect fail "a tracked app .env" "$d"

d="$(case_repo)"; mkdir -p "$d/backup/services"; printf 'X=1\n' > "$d/backup/services/planka.env"
git -C "$d" add -f backup/services/planka.env
expect fail "a tracked backup service env" "$d"

d="$(case_repo)"; mkdir -p "$d/apps/x"; printf 'SECRET=\n' > "$d/apps/x/.env.example"
expect pass "an env example" "$d"

if [[ $failures -ne 0 ]]; then
  echo "$failures case(s) failed"
  exit 1
fi
echo "all check-secrets-encrypted cases passed"
