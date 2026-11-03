#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2029  # commands are built here and run on the box over ssh on purpose
# orchestrate.sh — shared helpers for the provision.sh / restore.sh orchestrators.
#
# Sourced, not executed. The sourcing script must `set -euo pipefail` and set:
#   HOST_ALIAS   inventory host alias (also the ~/.ssh/config alias)
#   DRY_RUN      "1" to print mutating commands instead of running them (default 0)
#
# Design rules:
#   - Read-only guards (ssh_box/remote_test/inv_get) ALWAYS execute, even under
#     --dry-run, so the printed plan reflects the real skip/run decisions.
#   - Mutating actions go through run()/run_box() and honour DRY_RUN.
#   - Prefer real box/inventory state over marker files (see the orchestrators).

# --- output framing --------------------------------------------------------
_C_RESET=$'\033[0m'; _C_BOLD=$'\033[1m'; _C_GREEN=$'\033[32m'
_C_YELLOW=$'\033[33m'; _C_RED=$'\033[31m'; _C_BLUE=$'\033[34m'

# Exported so the sourcing script's EXIT trap can name the failed stage.
export CURRENT_STAGE=""
stage() { CURRENT_STAGE="$*"; printf '\n%s== %s ==%s\n' "$_C_BOLD$_C_BLUE" "$*" "$_C_RESET"; }
info()  { printf '  %s\n' "$*"; }
ok()    { printf '  %s✓%s %s\n' "$_C_GREEN" "$_C_RESET" "$*"; }
skip()  { printf '  %s-%s %s (skip)\n' "$_C_YELLOW" "$_C_RESET" "$*"; }
warn()  { printf '  %s!%s %s\n' "$_C_YELLOW" "$_C_RESET" "$*" >&2; }
die()   { printf '\n%sERROR:%s %s\n' "$_C_RED" "$_C_RESET" "$*" >&2; exit 1; }

# run <cmd...> — execute, or (under DRY_RUN) print. For simple argv commands only
# (no shell pipes/redirection — handle those inline with a DRY_RUN check).
run() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '  %s[dry-run]%s %s\n' "$_C_YELLOW" "$_C_RESET" "$*"
    return 0
  fi
  "$@"
}

# --- preflight -------------------------------------------------------------
require_cmd() {
  local missing=()
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  [[ ${#missing[@]} -eq 0 ]] || die "missing required command(s): ${missing[*]}"
}

# A server repo: has the scaffold submodule, scripts/, and the compose stack.
# (ansible/hosts is NOT asserted here — restore.sh materialises it from the
# bundle after this check.)
require_repo_root() {
  [[ -d scaffold && -d scripts && -f docker-compose.yml ]] \
    || die "run from a server-repo root (needs scaffold/, scripts/, docker-compose.yml)."
}

require_inventory() {
  [[ -f ansible/hosts ]] \
    || die "ansible/hosts not found — cp ansible/hosts.example ansible/hosts and set your host + IP."
}

ensure_galaxy() {
  if ansible-galaxy collection list devsec.hardening >/dev/null 2>&1; then
    skip "ansible-galaxy collections already installed"
  else
    run ansible-galaxy collection install -r scaffold/ansible/requirements.yml
  fi
}

# --- ansible ---------------------------------------------------------------
# ans <play-relpath> [extra ansible-playbook args...]
# Sets the resilient transport config explicitly (ansible.cfg only auto-loads
# from cwd) and limits to HOST_ALIAS.
ans() {
  local play="$1"; shift
  run env ANSIBLE_CONFIG=scaffold/ansible/ansible.cfg \
    ansible-playbook -i ansible/hosts -l "$HOST_ALIAS" "$play" "$@"
}

# --- ssh -------------------------------------------------------------------
# ssh_box <cmd>       run <cmd> on the box, stream output, return its status.
# remote_test <cmd>   run <cmd> quietly, return only the status (for guards).
# run_box <cmd>       DRY_RUN-aware mutating remote command.
# All use accept-new host keys so a rebuilt box never triggers an interactive
# yes/no prompt (which would breach the two-prompt budget).
_SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes)

# The ssh destination. Defaults to HOST_ALIAS (~/.ssh/config). restore.sh sets
# SSH_TARGET to <user>@<new-ip> because a rebuilt box has no matching alias yet.
_target() { printf %s "${SSH_TARGET:-$HOST_ALIAS}"; }

ssh_box() {
  ssh "${_SSH_OPTS[@]}" "$(_target)" "bash -lc $(printf '%q' "$1")"
}

remote_test() {
  ssh "${_SSH_OPTS[@]}" "$(_target)" "bash -lc $(printf '%q' "$1")" \
    >/dev/null 2>&1
}

run_box() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '  %s[dry-run]%s ssh %s %s\n' "$_C_YELLOW" "$_C_RESET" "$(_target)" "$1"
    return 0
  fi
  ssh "${_SSH_OPTS[@]}" "$(_target)" "bash -lc $(printf '%q' "$1")"
}

# deploy_reachable — true once bootstrap ran and the deploy user has sudo. The
# honest "bootstrap already done" signal; also correct after hardening disables
# root login (so we never retry a now-refused root connection).
deploy_reachable() {
  ssh -G "$(_target)" >/dev/null 2>&1 || return 1
  remote_test 'sudo -n true'
}

# --- secret placement ------------------------------------------------------
# install_secret_remote <local-relpath> — copy a local secret to /opt/deploy on
# the box at mode 0600, owner deploy. No-op if the local file is missing. Uses a
# mode-700 temp dir (never a world-readable /tmp window).
install_secret_remote() {
  local rel="$1"
  [[ -f "$rel" ]] || return 0
  local base; base="$(basename "$rel")"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '  %s[dry-run]%s install %s -> /opt/deploy/%s (0600 deploy)\n' \
      "$_C_YELLOW" "$_C_RESET" "$rel" "$rel"
    return 0
  fi
  local tgt tmp
  tgt="$(_target)"
  tmp="$(ssh "${_SSH_OPTS[@]}" "$tgt" 'd=$(mktemp -d) && chmod 700 "$d" && printf %s "$d"')"
  [[ -n "$tmp" ]] || die "could not create remote temp dir for $rel"
  scp "${_SSH_OPTS[@]}" -q "$rel" "$tgt:$tmp/$base"
  ssh "${_SSH_OPTS[@]}" "$tgt" \
    "sudo install -D -o deploy -g deploy -m 600 $tmp/$base /opt/deploy/$rel && rm -rf $tmp"
  ok "placed /opt/deploy/$rel (0600)"
}

# The canonical not-in-git secret set (matches make-recovery-bundle.sh). Places
# whatever exists in the local checkout onto the box.
SECRET_GLOBS=(".env" "apps/*/.env" "backup/config.env" "backup/services/*.env" "docker-compose.override.yml")
install_all_secrets_remote() {
  local g f
  for g in "${SECRET_GLOBS[@]}"; do
    for f in $g; do
      if [[ -e "$f" ]]; then install_secret_remote "$f"; fi
    done
  done
  return 0
}

# --- inventory (INI) -------------------------------------------------------
# First non-comment host alias (first token of the host line under [servers]).
inv_host_alias() {
  awk '
    /^[[:space:]]*#/ { next }
    /^\[servers\]/   { inhdr=1; next }
    /^\[/            { inhdr=0; next }
    inhdr && NF>0    { print $1; exit }
  ' ansible/hosts
}

# inv_get <key> — value of a host-line token OR a [servers:vars] line. Empty if
# unset. Ignores commented lines.
inv_get() {
  local key="$1"
  awk -v k="$key" '
    /^[[:space:]]*#/ { next }
    {
      for (i=1; i<=NF; i++) {
        if (index($i, k"=") == 1) { print substr($i, length(k)+2); exit }
      }
    }
  ' ansible/hosts
}

# inv_set_hostline <key> <value> — replace-or-append a key=value token on the
# active host line (the first non-comment line carrying ansible_host=).
inv_set_hostline() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$value" '
    BEGIN { done=0 }
    /^\[servers\]/ { inhdr=1; print; next }
    /^\[/          { inhdr=0; print; next }
    inhdr && !done && $0 !~ /^[[:space:]]*#/ && /ansible_host=/ {
      found=0
      for (i=1; i<=NF; i++) if (index($i, k"=")==1) { $i=k"="v; found=1 }
      if (!found) $0 = $0 " " k"="v
      done=1; print; next
    }
    { print }
  ' ansible/hosts > "$tmp" && mv "$tmp" ansible/hosts
}

# is_placeholder <value> — true for empty or example/stub values that mean
# "not really set yet".
is_placeholder() {
  local v="$1"
  [[ -z "$v" ]] && return 0
  case "$v" in
    *REPLACE*|*YOUR_*|"<"*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- gates -----------------------------------------------------------------
# The three site-play failure gates. deadman + log-export must be set (or
# explicitly waived); notify_ntfy_url is a known constant we can auto-seed.
validate_gates() {
  local v
  v="$(inv_get notify_ntfy_url)"
  if is_placeholder "$v"; then
    run inv_set_hostline notify_ntfy_url 'http://127.0.0.1:8080/alerts'
    ok "seeded notify_ntfy_url=http://127.0.0.1:8080/alerts (loopback; token wired post-deploy)"
  fi

  v="$(inv_get notify_deadman_url)"
  if is_placeholder "$v" && [[ "$(inv_get notify_deadman_accept_none)" != "true" ]]; then
    die "notify_deadman_url is unset. Set it in ansible/hosts (Gatus/Healthchecks external endpoint), or set notify_deadman_accept_none=true to knowingly run without a host-down alarm."
  fi

  v="$(inv_get log_export_s3_uri)"
  if is_placeholder "$v" && [[ "$(inv_get log_export_accept_none)" != "true" ]]; then
    die "log_export_s3_uri is unset. Run scripts/aws-logs-setup.py --write-hosts (or pass --aws-logs-* to provision.sh), or set log_export_accept_none=true to skip off-host log export."
  fi
}

# --- recovery bundle currency ---------------------------------------------
# bundle_current — true when /opt/deploy/.recovery-bundle-last exists and no
# captured secret is newer than it (mirrors post-provision-smoke-test.sh).
bundle_current() {
  local state
  state="$(ssh_box 'm=/opt/deploy/.recovery-bundle-last; if [ ! -f "$m" ]; then echo MISSING; else n=$( { find /opt/deploy/.env /opt/deploy/apps -type f -name ".env" -newer "$m"; sudo find /etc/restic -type f -name "*.env" -newer "$m"; } 2>/dev/null | head -1 ); [ -n "$n" ] && echo STALE || echo OK; fi' 2>/dev/null || echo ERROR)"
  [[ "$state" == "OK" ]]
}

# ---------------------------------------------------------------------------
# SOPS recovery set (docs/13-secrets.md, Decision 2). A server that keeps its
# secrets in SOPS holds the inventory in secrets/recovery.sops (encrypted to
# the owner and recovery keys) and the restic configuration in secrets/backup/.
# These helpers let restore.sh rebuild such a server from the repo and one of
# those keys, with no bundle.
# ---------------------------------------------------------------------------
sops_dotenv() {  # sops_dotenv <file>  — decrypt one dotenv file to stdout
  sops --decrypt --input-type dotenv --output-type dotenv "$1"
}
# Write ansible/hosts (and, for a repo that still carries the /etc/restic
# tarball of the earlier layout, backup/) from secrets/recovery.sops, then
# render secrets/backup/*.sops into backup/ so ansible/backup.yml can install
# /etc/restic. Nothing else is decrypted on the laptop: the apps' env files are
# rendered on the box by its own key once the secrets are re-keyed to it.
recovery_set_from_sops() {
  [[ -f secrets/recovery.sops ]] || die "secrets/recovery.sops not found: this repo does not keep its recovery set in SOPS"
  local plain
  plain="$(sops_dotenv secrets/recovery.sops)" || die "could not decrypt secrets/recovery.sops (is the owner or recovery age key in SOPS_AGE_KEY_FILE?)"
  local hosts_b64 restic_b64
  hosts_b64="$(printf '%s\n' "$plain" | sed -n 's/^ANSIBLE_HOSTS_B64=//p' | head -1)"
  restic_b64="$(printf '%s\n' "$plain" | sed -n 's/^RESTIC_ETC_TGZ_B64=//p' | head -1)"
  [[ -n "$hosts_b64" ]] || die "secrets/recovery.sops carries no ANSIBLE_HOSTS_B64"
  (umask 077; printf '%s' "$hosts_b64" | base64 -d > ansible/hosts) || die "could not write ansible/hosts"
  ok "wrote ansible/hosts from secrets/recovery.sops (0600)"
  if [[ -n "$restic_b64" ]]; then
    mkdir -p backup/services
    (umask 077; printf '%s' "$restic_b64" | base64 -d | tar -xz -C backup --no-same-owner) \
      || die "could not unpack the restic configuration from secrets/recovery.sops"
    ok "unpacked backup/ from the restic tarball in secrets/recovery.sops"
  fi
  local f out n=0
  while IFS= read -r f; do
    out="${f#secrets/}"; out="${out%.sops}"
    mkdir -p "$(dirname "$out")"
    (umask 077; sops_dotenv "$f" > "$out") || die "could not decrypt $f"
    n=$((n+1))
  done < <(find secrets/backup -type f -name '*.sops' 2>/dev/null | sort)
  (( n == 0 )) || ok "rendered $n restic file(s) from secrets/backup/ into backup/ (0600)"
  [[ -f backup/config.env ]] || warn "no backup/config.env: ansible/backup.yml will have nothing to install; the restic repository password must come from somewhere"
}
# The new box has a new server age key. Put its public half on the secrets
# rule in .sops.yaml in place of the old server key, re-encrypt every secrets
# file to it (updatekeys needs the owner or recovery key), and commit. The
# commit must reach main before the box can render: the deploy pulls main.
rekey_secrets_to_box() {
  local pub old
  pub="$(ssh_box 'sudo cat /etc/vps-scaffold/age/key.pub' 2>/dev/null | tr -d '[:space:]')"
  [[ "$pub" =~ ^age1[0-9a-z]+$ ]] || die "could not read the new server key (/etc/vps-scaffold/age/key.pub); has site-first-run run?"
  if grep -q "$pub" .sops.yaml; then
    ok "the new server key is already on .sops.yaml"
  else
    # The server key is the one on the general secrets rule that the recovery
    # rule does not carry (recovery.sops is never encrypted to the server).
    old="$(python3 - "$pub" <<'PY'
import re, sys
text = open(".sops.yaml").read()
rules = re.split(r"\n\s*-\s+path_regex:", text)[1:]
keysets = [set(re.findall(r"age1[0-9a-z]+", r)) for r in rules]
recovery = set().union(*(k for r, k in zip(rules, keysets) if "recovery" in r.split("\n", 1)[0]))
general = set().union(*(k for r, k in zip(rules, keysets) if "recovery" not in r.split("\n", 1)[0]))
server = general - recovery
print(server.pop() if len(server) == 1 else "")
PY
)"
    if [[ -n "$old" ]]; then
      run sed -i.bak "s/$old/$pub/" .sops.yaml && rm -f .sops.yaml.bak
      ok "replaced the old server key with the new one in .sops.yaml"
    else
      die "could not identify the old server key in .sops.yaml; add $pub to the secrets rule by hand, run 'sops updatekeys -y' on every secrets file except recovery.sops, commit, and re-run"
    fi
  fi
  local f
  while IFS= read -r f; do
    run sops updatekeys -y "$f" >/dev/null
  done < <(find secrets -type f -name '*.sops' ! -name recovery.sops | sort)
  ok "re-encrypted the secrets to the new server key"
  if [[ "${DRY_RUN:-0}" != "1" ]] && ! git diff --quiet -- .sops.yaml secrets; then
    run git add .sops.yaml secrets
    run git commit -q -m "secrets: re-key to the rebuilt server's age key"
    ok "committed the re-key; it must reach main before the next stage"
  fi
}

