#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export ANSIBLE_HOME="${ANSIBLE_HOME:-/tmp/ansible}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/.cache}"
export ANSIBLE_LOCAL_TEMP="${ANSIBLE_LOCAL_TEMP:-/tmp/ansible/tmp}"
export ANSIBLE_REMOTE_TEMP="${ANSIBLE_REMOTE_TEMP:-/tmp/ansible/tmp}"

mkdir -p "$ANSIBLE_HOME" "$XDG_CACHE_HOME" "$ANSIBLE_LOCAL_TEMP" "$REPO_ROOT/reports"

INVENTORY_FILE="$(mktemp /tmp/vps-scaffold-ci-inventory.XXXXXX)"
SSH_KEY_FILE="$(mktemp /tmp/vps-scaffold-ci-key.XXXXXX)"
trap 'rm -f "$INVENTORY_FILE" "$SSH_KEY_FILE" "$SSH_KEY_FILE.pub"' EXIT

cat > "$INVENTORY_FILE" <<'EOF'
[all]
ci_runner ansible_connection=local ansible_python_interpreter=/usr/bin/python3
EOF

if [[ -z "${DEPLOY_USER_PUBLIC_KEY:-}" ]]; then
  rm -f "$SSH_KEY_FILE"
  ssh-keygen -q -t ed25519 -N '' -C github-actions-ci -f "$SSH_KEY_FILE" >/dev/null
  DEPLOY_USER_PUBLIC_KEY="$(cat "$SSH_KEY_FILE.pub")"
fi

cd "$REPO_ROOT"

ansible-playbook -i "$INVENTORY_FILE" ansible/bootstrap.yml \
  -e "{\"deploy_user_public_key\": \"${DEPLOY_USER_PUBLIC_KEY}\"}"

# GitHub's Ubuntu 24.04 runner image currently includes an AppArmor profile
# that causes blanket aa-enforce runs to abort before we reach the audit step.
# Skip only that profile-mode task in CI so OpenSCAP can report the resulting
# posture instead of the workflow failing early.
ansible-playbook -i "$INVENTORY_FILE" ansible/site-first-run.yml \
  -e baseline_manage_apparmor_profile_modes=false
ansible-playbook -i "$INVENTORY_FILE" ansible/audit-openscap.yml
ansible-playbook -i "$INVENTORY_FILE" ansible/audit-docker.yml
