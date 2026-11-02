#!/usr/bin/env bash
# provision.sh — one-shot, idempotent, re-runnable full provision of a VPS.
#
# Chains the (already idempotent) scaffold plays + setup scripts into a single
# converging run: preflight -> bootstrap -> hardening -> AWS -> backups -> deploy
# -> alerting -> recovery bundle -> strict verify. Re-running skips completed
# stages by inspecting real box/inventory state.
#
# Two prompts, both skipped on a converged re-run:
#   - root credential  (bootstrap, only when the provider gave a root password)
#   - bundle passphrase (make-recovery-bundle.sh)
#
# Manual bookends (out of scope by design): create the VPS; cut DNS over.
#
# Usage:
#   scripts/provision.sh [HOST_ALIAS] [options]
#     --dry-run                 print what would run; mutate nothing
#     --ask-pass                force root-password bootstrap (else auto-detected)
#     --aws-backup-bucket NAME  --aws-backup-user NAME   set up the restic bucket
#     --aws-logs-bucket NAME    --aws-logs-user NAME     set up the log-export bucket
#     --aws-profile NAME        --aws-region NAME        (for the AWS steps)
#     --skip-bundle             don't create the recovery bundle this run
#     --force-bundle            (re)create the bundle even if current
#   HOST_ALIAS defaults to the first host in ansible/hosts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091  # lives beside this file in scaffold/scripts/server/lib
# shellcheck source=lib/orchestrate.sh
source "$SCRIPT_DIR/lib/orchestrate.sh"
cd "${SERVER_ROOT:-$SCRIPT_DIR/../../..}"

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; }

DRY_RUN=0
FORCE_ASK_PASS=0
AWS_BACKUP_BUCKET="" AWS_BACKUP_USER="" AWS_LOGS_BUCKET="" AWS_LOGS_USER=""
AWS_PROFILE="" AWS_REGION=""
SKIP_BUNDLE=0 FORCE_BUNDLE=0
HOST_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1 ;;
    --ask-pass) FORCE_ASK_PASS=1 ;;
    --aws-backup-bucket) AWS_BACKUP_BUCKET="$2"; shift ;;
    --aws-backup-user) AWS_BACKUP_USER="$2"; shift ;;
    --aws-logs-bucket) AWS_LOGS_BUCKET="$2"; shift ;;
    --aws-logs-user) AWS_LOGS_USER="$2"; shift ;;
    --aws-profile) AWS_PROFILE="$2"; shift ;;
    --aws-region) AWS_REGION="$2"; shift ;;
    --skip-bundle) SKIP_BUNDLE=1 ;;
    --force-bundle) FORCE_BUNDLE=1 ;;
    --*) die "unknown option: $1 (see --help)" ;;
    *) HOST_ARG="$1" ;;
  esac
  shift
done
export DRY_RUN

on_exit() {
  local rc=$?
  [[ $rc -ne 0 ]] && printf '\n%sInterrupted at:%s %s — fix, then re-run the same command; completed stages skip.\n' \
    "$_C_YELLOW" "$_C_RESET" "${CURRENT_STAGE:-preflight}" >&2
  return 0
}
trap on_exit EXIT

# --- 0/10 preflight + gates ------------------------------------------------
stage "0/10 Preflight + inventory gates"
require_repo_root
require_inventory
require_cmd ansible-playbook ansible-galaxy ssh scp git python3 openssl
ensure_galaxy
HOST_ALIAS="${HOST_ARG:-$(inv_host_alias)}"
[[ -n "$HOST_ALIAS" ]] || die "no host found in ansible/hosts"
ssh -G "$HOST_ALIAS" >/dev/null 2>&1 || die "no ~/.ssh/config entry for '$HOST_ALIAS' (needs Host/HostName/User/IdentityFile)"
validate_gates
ok "host: $HOST_ALIAS ($(inv_get ansible_host))"

# --- 1/10 bootstrap --------------------------------------------------------
stage "1/10 Bootstrap (users, deploy helper)"
if deploy_reachable; then
  skip "deploy user reachable with sudo — bootstrap already done"
else
  askpass=()
  if [[ "$FORCE_ASK_PASS" == "1" ]]; then
    askpass=(--ask-pass)
  else
    ip="$(inv_get ansible_host)"
    if ! ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "root@$ip" true 2>/dev/null; then
      askpass=(--ask-pass)
      info "root key login unavailable — will prompt for the root password"
    fi
  fi
  ans scaffold/ansible/bootstrap.yml "${askpass[@]}"
fi

# --- 2/10 deploy-access gate ----------------------------------------------
stage "2/10 Verify deploy access (do not lock out)"
if deploy_reachable; then
  ok "deploy has passwordless sudo"
elif [[ "$DRY_RUN" == "1" ]]; then
  info "[dry-run] would verify deploy sudo once the box is bootstrapped"
else
  die "deploy user cannot sudo on $HOST_ALIAS — refusing to harden (would lock you out). Check bootstrap output."
fi

# --- 3/10 AWS setup --------------------------------------------------------
stage "3/10 AWS setup (backups + log export)"
if [[ -z "$AWS_BACKUP_BUCKET$AWS_LOGS_BUCKET" ]]; then
  skip "no --aws-* flags — assuming AWS is configured manually"
else
  aws_common=()
  [[ -n "$AWS_PROFILE" ]] && aws_common+=(--profile "$AWS_PROFILE")
  [[ -n "$AWS_REGION" ]] && aws_common+=(--region "$AWS_REGION")
  if [[ -n "$AWS_BACKUP_BUCKET" ]]; then
    [[ -n "$AWS_BACKUP_USER" ]] || die "--aws-backup-bucket needs --aws-backup-user"
    cur="$(grep -E '^AWS_ACCESS_KEY_ID=' backup/config.env 2>/dev/null | cut -d= -f2- || true)"
    if is_placeholder "$cur"; then
      run python3 scripts/aws-backup-setup.py --bucket "$AWS_BACKUP_BUCKET" --iam-user "$AWS_BACKUP_USER" --write-config "${aws_common[@]}"
      if [[ "$DRY_RUN" != "1" ]]; then
        cur="$(grep -E '^AWS_ACCESS_KEY_ID=' backup/config.env 2>/dev/null | cut -d= -f2- || true)"
        is_placeholder "$cur" && die "backup access key still unset — an old key exists on the IAM user; delete it in AWS and re-run, or paste the saved secret into backup/config.env."
      fi
    else
      skip "backup/config.env already has AWS creds"
    fi
  fi
  if [[ -n "$AWS_LOGS_BUCKET" ]]; then
    [[ -n "$AWS_LOGS_USER" ]] || die "--aws-logs-bucket needs --aws-logs-user"
    if is_placeholder "$(inv_get log_export_aws_access_key_id)"; then
      run python3 scripts/aws-logs-setup.py --bucket "$AWS_LOGS_BUCKET" --iam-user "$AWS_LOGS_USER" --write-hosts "${aws_common[@]}"
      if [[ "$DRY_RUN" != "1" ]]; then
        is_placeholder "$(inv_get log_export_aws_access_key_id)" && die "log-export access key still unset — an old key exists on the IAM user; delete it in AWS and re-run, or paste the saved secret into ansible/hosts."
      fi
    else
      skip "ansible/hosts already has log_export creds"
    fi
  fi
fi

# --- 4/10 site hardening ---------------------------------------------------
stage "4/10 Site hardening"
if [[ "$DRY_RUN" == "1" ]] && ! deploy_reachable; then
  info "[dry-run] would run site-first-run.yml (box not yet bootstrapped)"
elif remote_test 'sudo test -f /var/lib/aide/aide.db'; then
  info "AIDE DB present — applying site-quick.yml"
  ans scaffold/ansible/site-quick.yml
else
  info "first run — applying site-first-run.yml (safe apt upgrade + AIDE init)"
  ans scaffold/ansible/site-first-run.yml
fi

# --- 5/10 /opt/deploy clone + secrets --------------------------------------
stage "5/10 /opt/deploy clone + local secrets"
if remote_test 'test -d /opt/deploy/.git'; then
  skip "/opt/deploy is already a clone"
else
  origin="$(git remote get-url origin 2>/dev/null || true)"
  [[ -n "$origin" ]] || die "no git 'origin' remote — cannot clone /opt/deploy on the box"
  run_box "git clone --recurse-submodules $origin /opt/deploy"
fi
install_all_secrets_remote

# --- 6/10 backups ----------------------------------------------------------
stage "6/10 Backups (restic + /etc/restic)"
ans ansible/backup.yml
if [[ "$DRY_RUN" != "1" ]]; then
  if remote_test 'sudo test -f /etc/restic/config.env && sudo test -d /etc/restic/services'; then
    ok "restic config installed (repo reachability proven by backup/verify timers)"
  else
    warn "/etc/restic not fully populated — check backup/config.env + backup/services/*.env"
  fi
fi

# --- 7/10 deploy the stack -------------------------------------------------
stage "7/10 Deploy the stack (./deploy)"
run_box './deploy'

# --- 8/10 ntfy token + rewire ----------------------------------------------
stage "8/10 ntfy token + notify rewire"
if ! is_placeholder "$(inv_get notify_ntfy_token)"; then
  skip "notify_ntfy_token already set"
elif [[ "$DRY_RUN" == "1" ]]; then
  info "[dry-run] would mint an ntfy token, write it to ansible/hosts, and re-run site-quick"
else
  token="$(ssh_box 'cd /opt/deploy && docker compose exec -T ntfy ntfy token add admin' 2>/dev/null | grep -Eo 'tk_[A-Za-z0-9]+' | head -1 || true)"
  [[ -n "$token" ]] || die "could not mint ntfy token — is ntfy up? (ssh $HOST_ALIAS 'cd /opt/deploy && docker compose ps ntfy'). In restricted mode, mint it manually and set notify_ntfy_token in ansible/hosts."
  inv_set_hostline notify_ntfy_token "$token"
  ok "minted + wrote notify_ntfy_token"
  ans scaffold/ansible/site-quick.yml
fi

# --- 9/10 recovery bundle --------------------------------------------------
stage "9/10 Recovery bundle"
if [[ "$SKIP_BUNDLE" == "1" ]]; then
  skip "--skip-bundle"
elif [[ "$FORCE_BUNDLE" != "1" ]] && bundle_current; then
  skip "recovery bundle is current"
elif [[ "$DRY_RUN" == "1" ]]; then
  info "[dry-run] would run make-recovery-bundle.sh (interactive passphrase) and scp it off"
else
  info "creating the recovery bundle — you will be prompted for a passphrase..."
  ssh -t -o StrictHostKeyChecking=accept-new "$HOST_ALIAS" 'cd /opt/deploy && sudo scripts/make-recovery-bundle.sh'
  scp -o StrictHostKeyChecking=accept-new "$HOST_ALIAS:~/recovery-bundle-*.tar.gz.enc" .
  warn "STORE the bundle and its passphrase as TWO separate password-manager entries, offsite."
fi

# --- 10/10 verify ----------------------------------------------------------
stage "10/10 Verify (smoke --strict)"
if [[ "$DRY_RUN" == "1" ]]; then
  info "[dry-run] would run: scripts/post-provision-smoke-test.sh $HOST_ALIAS --require-backup --strict"
else
  bash scripts/post-provision-smoke-test.sh "$HOST_ALIAS" --require-backup --strict
fi

stage "Done"
ok "$HOST_ALIAS provisioned. Remaining manual bookend: cut DNS over when ready."
