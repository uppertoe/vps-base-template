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

# GitHub's Ubuntu 24.04 runner image still trips on blanket AppArmor
# profile-mode enforcement before the audit step. Keep only that CI-specific
# skip in place so the workflow reaches the reports. Also keep AIDE DB
# initialization off in CI while iterating; it makes the runner take well over
# an hour and still does not produce a stable signal on the hosted image.
ansible-playbook -i "$INVENTORY_FILE" ansible/site-first-run.yml \
  -e baseline_manage_apparmor_profile_modes=false \
  -e baseline_initialize_aide_database=false

DIAGNOSTICS_DIR="$REPO_ROOT/reports/ci-diagnostics"
mkdir -p "$DIAGNOSTICS_DIR"

{
  echo "# CI network diagnostics"
  echo
  echo "## timestamp"
  date -u '+%Y-%m-%dT%H:%M:%SZ'
  echo
  echo "## ip -brief addr"
  ip -brief addr || true
  echo
  echo "## ss -lntup"
  ss -lntup || true
  echo
  echo "## ufw status numbered"
  ufw status numbered || true
  echo
  echo "## ufw show raw"
  ufw show raw || true
  echo
  echo "## iptables -S"
  iptables -S || true
  echo
  echo "## iptables -S DOCKER-USER"
  iptables -S DOCKER-USER || true
  echo
  echo "## docker ps -a"
  docker ps -a || true
} > "$DIAGNOSTICS_DIR/network-and-firewall.txt"

ansible-playbook -i "$INVENTORY_FILE" ansible/audit-openscap.yml
ansible-playbook -i "$INVENTORY_FILE" ansible/audit-docker.yml
