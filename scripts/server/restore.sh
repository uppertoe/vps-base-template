#!/usr/bin/env bash
# restore.sh — one-shot rebuild of a lost box from the recovery set + offsite
# restic backups. Automates the docs/09 disaster-recovery drill end to end.
#
# Run from a FRESH clone of this server repo (git clone --recurse-submodules).
# Follows the mandatory docs/09 order: provision -> place secrets -> install
# restic -> deploy -> restore data. Resumable: re-run the same command after a
# mid-way failure; completed stages skip.
#
# Two sources for the recovery set (docs/09, docs/13):
#   --from-sops   the repo keeps it in SOPS: secrets/recovery.sops (inventory)
#                 and secrets/backup/ (restic). Needs sops and the owner or
#                 recovery age key in SOPS_AGE_KEY_FILE. After the box is
#                 hardened, the secrets are re-keyed to its new server key and
#                 that commit must reach main before the deploy stage.
#   <bundle.enc>  the older encrypted tarball from make-recovery-bundle.sh.
#
# Prompts: the bundle passphrase (bundle mode, stage 1) and the root credential
# (bootstrap, stage 3; --ask-pass).
#
# Manual bookend: cut DNS over to the new IP (stage 9 prints the instruction).
#
# Usage:
#   scripts/restore.sh [--dry-run] [--force-data] --from-sops <new-ip>
#   scripts/restore.sh [--dry-run] [--force-data] <recovery-bundle.enc> <new-ip>
#     --list        list the bundle contents and exit (no decrypt to disk)
#     --dry-run     print what would run; mutate nothing
#     --force-data  re-run the data restore even if already done this rebuild
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091  # lives beside this file in scaffold/scripts/server/lib
# shellcheck source=lib/orchestrate.sh
source "$SCRIPT_DIR/lib/orchestrate.sh"
cd "${SERVER_ROOT:-$SCRIPT_DIR/../../..}"

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; }

DRY_RUN=0 FORCE_DATA=0 LIST_ONLY=0 FROM_SOPS=0
BUNDLE="" NEW_IP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1 ;;
    --force-data) FORCE_DATA=1 ;;
    --list) LIST_ONLY=1 ;;
    --from-sops) FROM_SOPS=1 ;;
    --*) die "unknown option: $1 (see --help)" ;;
    *) if [[ "$FROM_SOPS" == "1" && -z "$NEW_IP" ]]; then NEW_IP="$1"; elif [[ -z "$BUNDLE" ]]; then BUNDLE="$1"; elif [[ -z "$NEW_IP" ]]; then NEW_IP="$1"; else die "unexpected arg: $1"; fi ;;
  esac
  shift
done
export DRY_RUN

DEC_OPTS=(enc -d -aes-256-cbc -pbkdf2 -iter 600000)

if [[ "$LIST_ONLY" == "1" ]]; then
  [[ -f "$BUNDLE" ]] || die "bundle not found: $BUNDLE"
  openssl "${DEC_OPTS[@]}" -in "$BUNDLE" | tar -tz
  exit 0
fi

if [[ "$FROM_SOPS" == "1" ]]; then
  [[ -z "$BUNDLE" ]] || die "--from-sops takes only the new box IP, not a bundle"
  [[ -f secrets/recovery.sops ]] || die "--from-sops needs secrets/recovery.sops in this repo"
else
  [[ -f "$BUNDLE" ]] || die "recovery bundle not found: $BUNDLE"
fi
[[ "$NEW_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "the last arg must be the new box IP (got: '${NEW_IP:-}')"

on_exit() {
  local rc=$?
  [[ $rc -ne 0 ]] && printf '\n%sInterrupted at:%s %s — fix, then re-run the same command; completed stages skip.\n' \
    "$_C_YELLOW" "$_C_RESET" "${CURRENT_STAGE:-preflight}" >&2
  return 0
}
trap on_exit EXIT

# --- 0/10 preflight --------------------------------------------------------
stage "0/10 Preflight"
require_repo_root
require_cmd ansible-playbook ansible-galaxy ssh scp git python3 openssl tar
if [[ "$FROM_SOPS" == "1" ]]; then
  require_cmd sops base64
  [[ -f "${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}" ]] \
    || die "no age key at ${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}; put the owner or recovery key there (or set SOPS_AGE_KEY_FILE)"
fi
ensure_galaxy
if [[ "$FROM_SOPS" == "1" ]]; then ok "recovery set: SOPS (secrets/)  ->  new box: $NEW_IP"; else ok "bundle: $BUNDLE  ->  new box: $NEW_IP"; fi

# --- 1/10 the recovery set (prompt #1 in bundle mode) ----------------------
stage "1/10 Recover the inventory and restic configuration"
if [[ -f .restore-decrypted ]]; then
  skip "recovery set already placed this rebuild (.restore-decrypted)"
elif [[ "$DRY_RUN" == "1" ]]; then
  if [[ "$FROM_SOPS" == "1" ]]; then
    info "[dry-run] would decrypt secrets/recovery.sops into ansible/hosts and secrets/backup/*.sops into backup/"
  else
    info "[dry-run] would decrypt $BUNDLE (passphrase prompt) and lay secrets over the checkout"
  fi
elif [[ "$FROM_SOPS" == "1" ]]; then
  recovery_set_from_sops
  : > .restore-decrypted
else
  info "decrypting — you will be prompted for the bundle passphrase..."
  openssl "${DEC_OPTS[@]}" -in "$BUNDLE" | tar -xzv
  : > .restore-decrypted
  ok "restored ansible/hosts, .env, apps/*/.env, backup/* over the checkout"
fi

# --- 2/10 point inventory at the new IP -----------------------------------
stage "2/10 Retarget inventory + clear stale host key"
require_inventory
HOST_ALIAS="$(inv_host_alias)"
[[ -n "$HOST_ALIAS" ]] || die "no host in the decrypted ansible/hosts"
run inv_set_hostline ansible_host "$NEW_IP"
run ssh-keygen -R "$NEW_IP"
SSH_TARGET="$(inv_get ansible_user)@$NEW_IP"; [[ "$SSH_TARGET" == "@$NEW_IP" ]] && SSH_TARGET="deploy@$NEW_IP"
export SSH_TARGET
ok "host $HOST_ALIAS -> $NEW_IP (ssh as $SSH_TARGET)"

# --- 3/10 bootstrap (prompt #2) -------------------------------------------
stage "3/10 Bootstrap the fresh box"
if deploy_reachable; then
  skip "connect user reachable with sudo — bootstrap already done"
elif [[ "$DRY_RUN" == "1" ]]; then
  info "[dry-run] would run bootstrap.yml --ask-pass against $NEW_IP"
else
  ans scaffold/ansible/bootstrap.yml --ask-pass
fi

# --- 4/10 site hardening ---------------------------------------------------
stage "4/10 Site hardening (full first-run)"
if [[ "$DRY_RUN" == "1" ]] && ! deploy_reachable; then
  info "[dry-run] would run site-first-run.yml"
elif remote_test 'sudo test -f /var/lib/aide/aide.db'; then
  skip "AIDE DB present — hardening already applied"
else
  ans scaffold/ansible/site-first-run.yml
fi

# --- 5/10 /opt/deploy clone + secrets --------------------------------------
stage "5/10 /opt/deploy clone + secrets"
if remote_test 'test -d /opt/deploy/.git'; then
  skip "/opt/deploy already a clone"
else
  origin="$(git remote get-url origin 2>/dev/null || true)"
  [[ -n "$origin" ]] || die "no git 'origin' remote — cannot clone /opt/deploy"
  run_box "git clone --recurse-submodules $origin /opt/deploy"
fi
if [[ "$FROM_SOPS" == "1" ]]; then
  # The box renders its own env files from secrets/ at deploy, once they are
  # encrypted to its new server key; that commit has to be on main first.
  if [[ "$DRY_RUN" == "1" ]]; then
    info "[dry-run] would re-key secrets/ to the new server key, commit, and wait for that commit on main"
  else
    rekey_secrets_to_box
    git fetch -q origin main
    if ! git merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
      warn "the re-key commit is not on main yet. Push it (a PR if main is protected), merge, then re-run this same command; the stages so far skip."
      warn "  git push origin HEAD:restore/rekey-$NEW_IP"
      exit 2
    fi
    ok "the re-key commit is on main; the deploy stage can render on the box"
  fi
else
  install_all_secrets_remote
fi

# --- 6/10 backups (restic) -------------------------------------------------
stage "6/10 Install restic + verify repo reachable"
ans ansible/backup.yml
if [[ "$DRY_RUN" != "1" ]]; then
  remote_test 'sudo test -f /etc/restic/config.env' \
    || die "/etc/restic/config.env missing after backup.yml — cannot restore data."
  ok "restic config installed"
fi

# --- 7/10 deploy the stack (Postgres must be up before data restore) -------
stage "7/10 Deploy the stack (./deploy)"
run_box './deploy'

# --- 8/10 restore data from restic (disaster mode) -------------------------
stage "8/10 Restore data from backups"
if [[ "$FORCE_DATA" != "1" ]] && remote_test 'test -f /opt/deploy/.restore-data-done'; then
  skip "data already restored this rebuild (--force-data to repeat)"
elif [[ "$DRY_RUN" == "1" ]]; then
  info "[dry-run] would run: sudo RESTORE_NO_CONFIRM=true /opt/backup/restore.sh (restore ALL)"
else
  info "restoring all services from the latest snapshots..."
  run_box 'sudo RESTORE_NO_CONFIRM=true /opt/backup/restore.sh && touch /opt/deploy/.restore-data-done'
  ok "data restored"
fi

# --- 9/10 DNS cutover (manual bookend) ------------------------------------
stage "9/10 DNS cutover (manual)"
info "Point DNS at $NEW_IP (lower TTLs ahead of time for a faster switch):"
info "  - the apex + app subdomains -> $NEW_IP"
info "Then confirm the dead-man's switch + ntfy alerts reference the NEW host."

# --- 10/10 verify ----------------------------------------------------------
stage "10/10 Verify (smoke --strict)"
if [[ "$DRY_RUN" == "1" ]]; then
  info "[dry-run] would run: scripts/post-provision-smoke-test.sh $SSH_TARGET --require-backup --strict"
else
  bash scripts/post-provision-smoke-test.sh "$SSH_TARGET" --require-backup --strict || \
    warn "smoke test reported issues — review above (some checks depend on DNS cutover)."
fi

stage "Done"
ok "Rebuild complete. Record the time-to-serving in scaffold/docs/09-recovery.md (RTO log)."
