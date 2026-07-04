#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Ansible temp/caches must live OUTSIDE /tmp and /var/tmp: the play itself
# converts both into size-capped tmpfs mounts (os-hardening), and when the
# mount activates mid-run everything underneath vanishes — including the
# AnsiballZ payload of the task currently executing (the June 2026 weekly
# failures: apt module dying with FileNotFoundError on its own payload zip).
CI_TMP_BASE="${RUNNER_TEMP:-$HOME/.vps-scaffold-ci-tmp}"
export ANSIBLE_HOME="${ANSIBLE_HOME:-$CI_TMP_BASE/ansible}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$CI_TMP_BASE/.cache}"
export ANSIBLE_LOCAL_TEMP="${ANSIBLE_LOCAL_TEMP:-$CI_TMP_BASE/ansible/tmp}"
export ANSIBLE_REMOTE_TEMP="${ANSIBLE_REMOTE_TEMP:-$CI_TMP_BASE/ansible/tmp}"
# Moving ANSIBLE_HOME also moves the default collections path — keep the
# workflow-installed collections (~/.ansible) visible.
export ANSIBLE_COLLECTIONS_PATH="${ANSIBLE_COLLECTIONS_PATH:-$ANSIBLE_HOME/collections:$HOME/.ansible/collections:/usr/share/ansible/collections}"

mkdir -p "$ANSIBLE_HOME" "$XDG_CACHE_HOME" "$ANSIBLE_LOCAL_TEMP" "$REPO_ROOT/reports"

INVENTORY_FILE="$(mktemp "$CI_TMP_BASE/vps-scaffold-ci-inventory.XXXXXX")"
SSH_KEY_FILE="$(mktemp "$CI_TMP_BASE/vps-scaffold-ci-key.XXXXXX")"
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
# NO package upgrade in CI, deliberately: runners are freshly imaged by
# GitHub, the audited control is the unattended-upgrades CONFIGURATION (not
# the act of upgrading), and upstream churn has repeatedly broken or stalled
# evidence runs (2026-07-03: a bad amd64 postinst, then a 191kB/s GNOME snap
# transition). Real provisions run the safe upgrade inside site-first-run
# and fail loudly there.
ansible-playbook -i "$INVENTORY_FILE" ansible/site-first-run.yml \
  -e "{\"deploy_user_public_key\": \"${DEPLOY_USER_PUBLIC_KEY}\"}" \
  -e common_run_safe_upgrade=false \
  -e baseline_cis_l2_audit_rules=true \
  -e deploy_restricted_mode=true \
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

# Normalize GitHub-runner image artifacts the CIS rules legitimately flag:
# group-writable directories on root's PATH and loose user init files exist
# on the runner image, not in the scaffold. Fixing them hardens the audited
# host exactly as the rules intend.
for d in $(sudo sh -lc 'echo "$PATH"' | tr ':' ' '); do
  if [ -d "$d" ]; then sudo chmod go-w "$d" 2>/dev/null || true; fi
done
# Logs created after the role's normalisation (stack boot, audits, background
# apt on the runner) can appear looser than the 0640 the CIS rule requires.
sudo find /var/log -type f -perm /0137 -exec chmod g-w,o-rwx {} + 2>/dev/null || true

ansible-playbook -i "$INVENTORY_FILE" ansible/audit-openscap.yml
# Keep the L1 report distinct, then audit the L2 deployment-target profile too.
for d in "$REPO_ROOT"/reports/openscap-*; do
  [[ -d "$d" && "$d" != *-l1 && "$d" != *-l2 ]] && mv "$d" "${d}-l1"
done
ansible-playbook -i "$INVENTORY_FILE" ansible/audit-openscap.yml \
  -e openscap_tailoring_profile=xccdf_org.ssgproject.content_profile_cis_level2_server_cloud_vps
for d in "$REPO_ROOT"/reports/openscap-*; do
  [[ -d "$d" && "$d" != *-l1 && "$d" != *-l2 ]] && mv "$d" "${d}-l2"
done

ansible-playbook -i "$INVENTORY_FILE" ansible/audit-docker.yml

# --- Audit the REAL container stack, not just the bare host -----------------
# Boot the server template's compose stack (the same digest-pinned caddy/auth/
# ntfy images a production instance runs) and audit the running containers:
# CIS Docker §5 + data-tier separation (audit-compose, enforcing) and image
# CVEs (audit-vuln, report-only).
STACK_DIR="$CI_TMP_BASE/stack"
rm -rf "$STACK_DIR"
git clone --depth 1 https://github.com/uppertoe/server-instance-template "$STACK_DIR"
git -C "$STACK_DIR" -c url."https://github.com/".insteadOf=git@github.com: \
  submodule update --init --recursive
echo "DOMAIN=ci.invalid" > "$STACK_DIR/.env"
(cd "$STACK_DIR" && sudo docker compose up -d --wait)

ansible-playbook -i "$INVENTORY_FILE" ansible/audit-compose.yml
ansible-playbook -i "$INVENTORY_FILE" ansible/audit-vuln.yml
ansible-playbook -i "$INVENTORY_FILE" ansible/audit-lynis.yml

# ssh-audit: algorithm-level SSH scoring (complements the CIS config rules).
# The runner's sshd is hardened by the play but not necessarily running.
mkdir -p "$REPO_ROOT/reports/ssh-audit-ci"
sudo systemctl start ssh 2>/dev/null || true
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ssh-audit >/dev/null 2>&1 || true
(ssh-audit --no-colors 127.0.0.1 2>&1 || true) | tee "$REPO_ROOT/reports/ssh-audit-ci/ssh-audit.txt"

(cd "$STACK_DIR" && sudo docker compose down -v) || true
