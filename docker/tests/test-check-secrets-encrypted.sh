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
printf '#\n%s\n#   \n%s\n' "$enc_line" "$meta" > "$d/secrets/.env.sops"
expect pass "empty comment lines, which SOPS leaves unencrypted" "$d"

d="$(case_repo)"; mkdir -p "$d/secrets"; touch "$d/.sops.yaml"
printf '%s\n#x\n%s\n' "$enc_line" "$meta" > "$d/secrets/.env.sops"
expect fail "an unencrypted comment with content" "$d"

d="$(case_repo)"; mkdir -p "$d/secrets"; touch "$d/.sops.yaml"
printf 'SECRET_KEY=plaintext\n' > "$d/secrets/.env"
expect fail "a plain file under secrets/" "$d"

d="$(case_repo)"; mkdir -p "$d/secrets"; touch "$d/.sops.yaml"
printf 'Notes for operators\n' > "$d/secrets/README.md"
expect pass "a README under secrets/" "$d"

d="$(case_repo)"; mkdir -p "$d/secrets"; touch "$d/.sops.yaml"
printf 'sops:\n    age: []\n    mac: ENC[x]\nkey: ENC[y]\n' > "$d/secrets/recovery.sops"
expect fail "a YAML file (the deploy step reads dotenv only)" "$d"

for line in 'MY-KEY=plaintext' 'a.b=plaintext' ' KEY=plaintext' 'export KEY=plaintext' '# a plaintext comment' 'sops_foo=plaintext' 'plaintext with no equals'; do
  d="$(case_repo)"; mkdir -p "$d/secrets"; touch "$d/.sops.yaml"
  printf '%s\n%s\n%s\n' "$enc_line" "$line" "$meta" > "$d/secrets/.env.sops"
  expect fail "plaintext line: $line" "$d"
done

d="$(case_repo)"; mkdir -p "$d/secrets"; touch "$d/.sops.yaml"
printf '%s\n#ENC[AES256_GCM,data:c=,iv:d=,tag:e=,type:comment]\nEMPTY=\n\n%s\nsops_age__list_0__map_recipient=age1abc\nsops_age__list_0__map_enc=-----BEGIN AGE ENCRYPTED FILE-----\\nabc\\n-----END AGE ENCRYPTED FILE-----\\n\nsops_lastmodified=2026-11-02T00:00:00Z\nsops_unencrypted_suffix=_unencrypted\n' "$enc_line" "$meta" > "$d/secrets/.env.sops"
expect pass "a realistic encrypted file with comments, empty values and age metadata" "$d"

d="$(case_repo)"; mkdir -p "$d/secrets"; touch "$d/.sops.yaml"
printf '%s\nsops_kms__list_0__map_arn=arn:aws:kms:x\n%s\n' "$enc_line" "$meta" > "$d/secrets/.env.sops"
expect fail "a non-age key source" "$d"

# Whole files (docs/13 "Whole files"): the JSON document SOPS writes for a
# binary-type file, below a subdirectory of an app.
whole_doc='{"data":"ENC[AES256_GCM,data:abc=,iv:def=,tag:ghi=,type:str]","sops":{"age":[{"recipient":"age1abc","enc":"x"}],"lastmodified":"2026-11-04T00:00:00Z","mac":"ENC[AES256_GCM,data:m=,iv:a=,tag:b=,type:str]","version":"3.13.3"}}'

d="$(case_repo)"; mkdir -p "$d/secrets/apps/authelia/config"; touch "$d/.sops.yaml"
printf '%s\n' "$whole_doc" > "$d/secrets/apps/authelia/config/oidc.pem.sops"
expect pass "an encrypted whole file" "$d"

d="$(case_repo)"; mkdir -p "$d/secrets/apps/authelia/config"; touch "$d/.sops.yaml"
printf -- '-----BEGIN PRIVATE KEY-----\nplaintext\n' > "$d/secrets/apps/authelia/config/oidc.pem.sops"
expect fail "a plaintext key named as a whole file" "$d"

d="$(case_repo)"; mkdir -p "$d/secrets/apps/authelia/config"; touch "$d/.sops.yaml"
printf '{"data":"plaintext","sops":{"mac":"ENC[x]","version":"3.13.3"}}\n' > "$d/secrets/apps/authelia/config/oidc.pem.sops"
expect fail "a whole-file document whose data is not encrypted" "$d"

d="$(case_repo)"; mkdir -p "$d/secrets/apps/authelia/config"; touch "$d/.sops.yaml"
printf '%s\n' "${whole_doc/\"age\":/\"kms\":[{\"arn\":\"x\"}],\"age\":}" > "$d/secrets/apps/authelia/config/oidc.pem.sops"
expect fail "a whole file naming a non-age key source" "$d"

d="$(case_repo)"; mkdir -p "$d/secrets/apps/authelia"; touch "$d/.sops.yaml"
printf '%s\n' "$whole_doc" > "$d/secrets/apps/authelia/oidc.pem.sops"
expect fail "a whole file at an app's top level" "$d"

d="$(case_repo)"; mkdir -p "$d/secrets/backup"; touch "$d/.sops.yaml"
printf '%s\n' "$whole_doc" > "$d/secrets/backup/restic.key.sops"
expect fail "a whole file outside apps/" "$d"

d="$(case_repo)"; mkdir -p "$d/secrets/apps/authelia/config" "$d/apps/authelia/config"; touch "$d/.sops.yaml"
printf '%s\n' "$whole_doc" > "$d/secrets/apps/authelia/config/users_database.yml.sops"
printf 'users: {}\n' > "$d/apps/authelia/config/users_database.yml"
expect fail "a whole file whose rendered path git tracks" "$d"

d="$(case_repo)"; mkdir -p "$d/secrets"; touch "$d/.sops.yaml"
printf '%s\n' "$whole_doc" > "$d/secrets/recovery.sops"
expect fail "a recovery file in the binary form (it is a dotenv file)" "$d"

d="$(case_repo)"; printf 'X=1\n' > "$d/.env.local"; git -C "$d" add -f .env.local
expect fail "a tracked .env.local" "$d"

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
