#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2029  # commands are built here and run on the box over ssh on purpose
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash scripts/post-provision-smoke-test.sh [HOST_ALIAS] [OPTIONS]

Checks a real provisioned VPS over SSH.

Arguments:
  HOST_ALIAS         SSH host alias from ~/.ssh/config (default: myserver)

Options:
  --require-backup   Fail if the backup system is not deployed/configured
  --skip-backup      Skip backup-related checks entirely
  --strict           Promote monitoring/recovery WARNs to FAILs
                     (alias: --require-monitoring)
  -h, --help         Show this help
EOF
}

HOST_ALIAS="myserver"
REQUIRE_BACKUP=false
SKIP_BACKUP=false
STRICT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --require-backup)
      REQUIRE_BACKUP=true
      shift
      ;;
    --skip-backup)
      SKIP_BACKUP=true
      shift
      ;;
    --strict|--require-monitoring)
      STRICT=true
      shift
      ;;
    --*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      HOST_ALIAS="$1"
      shift
      ;;
  esac
done

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

header() {
  echo
  echo "== $* =="
}

pass() {
  echo "[PASS] $*"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo "[FAIL] $*" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

warn() {
  echo "[WARN] $*"
  WARN_COUNT=$((WARN_COUNT + 1))
}

remote() {
  local cmd="$1"
  ssh "${SSH_OPTS[@]}" "$HOST_ALIAS" "bash -lc $(printf '%q' "$cmd")"
}

check_remote() {
  local label="$1"
  local cmd="$2"
  if remote "$cmd" >/tmp/post-provision-smoke.out 2>/tmp/post-provision-smoke.err; then
    pass "$label"
  else
    fail "$label"
    if [[ -s /tmp/post-provision-smoke.err ]]; then
      sed 's/^/  /' /tmp/post-provision-smoke.err >&2
    elif [[ -s /tmp/post-provision-smoke.out ]]; then
      sed 's/^/  /' /tmp/post-provision-smoke.out >&2
    fi
  fi
}

# Like check_remote, but a failure is a WARN (soft) unless --strict is set, in
# which case it FAILs. For layers a box can run without but shouldn't in prod
# (alerting, off-host logs, a recovery bundle).
check_soft() {
  local label="$1"
  local cmd="$2"
  if remote "$cmd" >/tmp/post-provision-smoke.out 2>/tmp/post-provision-smoke.err; then
    pass "$label"
  elif "$STRICT"; then
    fail "$label"
    if [[ -s /tmp/post-provision-smoke.err ]]; then
      sed 's/^/  /' /tmp/post-provision-smoke.err >&2
    elif [[ -s /tmp/post-provision-smoke.out ]]; then
      sed 's/^/  /' /tmp/post-provision-smoke.out >&2
    fi
  else
    warn "$label (use --strict to require)"
  fi
}

# Emit a bare WARN, or FAIL under --strict, for a message computed inline
# (used where the check has more than two outcomes, e.g. bundle missing vs stale).
soft_note() {
  if "$STRICT"; then
    fail "$1"
  else
    warn "$1 (use --strict to require)"
  fi
}

# The suite makes ~25 short ssh calls. Reuse ONE connection (ControlMaster) so
# only the first pays the handshake — otherwise every check pays a full
# round-trip (seconds each over a distant link), the run drags into minutes, and
# each fresh connection is another chance to stall. -n keeps a check's ssh off
# the script's own stdin; BatchMode fails fast instead of blocking on a prompt;
# ConnectTimeout bounds the initial connect. Socket path stays short for the
# macOS 104-char AF_UNIX limit.
SSH_CONTROL="$(mktemp -u /tmp/pps-ssh.XXXXXX)"
SSH_OPTS=(-n -o BatchMode=yes -o ConnectTimeout=15
          -o ControlMaster=auto -o ControlPath="$SSH_CONTROL" -o ControlPersist=30s)

cleanup() {
  rm -f /tmp/post-provision-smoke.out /tmp/post-provision-smoke.err
  # Close the shared master connection (ControlPersist would otherwise linger).
  [[ -n "${SSH_CONTROL:-}" ]] && ssh -O exit -o ControlPath="$SSH_CONTROL" "$HOST_ALIAS" 2>/dev/null || true
}

trap cleanup EXIT

header "Connection"

if ssh -G "$HOST_ALIAS" >/tmp/post-provision-smoke.out 2>/tmp/post-provision-smoke.err; then
  pass "SSH config resolves for $HOST_ALIAS"
else
  fail "SSH config resolves for $HOST_ALIAS"
  sed 's/^/  /' /tmp/post-provision-smoke.err >&2
  exit 1
fi

check_remote "SSH login works" "true"

# Access mode detection (docs/05): connect as deploy in the default model, as
# admin once deploy_restricted_mode is enabled (deploy then has wrapper-only
# sudo and the sudo-based checks below need the admin identity).
REMOTE_USER="$(ssh "${SSH_OPTS[@]}" "$HOST_ALIAS" 'whoami' 2>/dev/null || echo unknown)"
case "$REMOTE_USER" in
  deploy)
    header "Access model: default (unrestricted deploy)"
    check_remote "Passwordless sudo works" "sudo -n true"
    check_remote "deploy has direct docker access" "docker --version >/dev/null"
    ;;
  admin)
    header "Access model: restricted (connected as admin)"
    check_remote "admin passwordless sudo works" "sudo -n true"
    check_remote "deploy sudoers is the wrapper allowlist" "sudo grep -q 'NOPASSWD:/usr/local/sbin/vps-deploy' /etc/sudoers.d/deploy && ! sudo grep -q 'NOPASSWD:ALL' /etc/sudoers.d/deploy"
    check_remote "deploy is not in the docker group" "! id -nG deploy | tr ' ' '\n' | grep -qx docker"
    check_remote "wrapper entrypoints installed" "sudo test -x /usr/local/sbin/vps-deploy && sudo test -x /usr/local/sbin/vps-app-manage && sudo test -x /usr/local/sbin/vps-app-logs"
    check_remote "~deploy/deploy delegates to vps-deploy" "sudo grep -q 'sudo /usr/local/sbin/vps-deploy' /home/deploy/deploy"
    ;;
  *)
    fail "Connected user is deploy or admin (got: $REMOTE_USER)"
    ;;
esac

header "Server"
check_remote "/opt/deploy exists and is owned by deploy" "[[ -d /opt/deploy ]] && [[ \$(stat -c '%U:%G' /opt/deploy) == 'deploy:deploy' ]]"
check_remote "deploy helper exists and is executable" "sudo test -x /home/deploy/deploy"
check_remote "Docker CLI is installed" "sudo docker --version >/dev/null"
check_remote "Docker Compose plugin is installed" "sudo docker compose version >/dev/null"
check_remote "Docker service is active" "sudo systemctl is-active --quiet docker"
check_remote "Docker service is enabled" "sudo systemctl is-enabled --quiet docker"
check_remote "docker-prune timer is active" "sudo systemctl is-active --quiet docker-prune.timer"
check_remote "docker-prune timer is enabled" "sudo systemctl is-enabled --quiet docker-prune.timer"

header "SSH Hardening"
check_remote "sshd disables password auth" "sudo sshd -T | grep -Fx 'passwordauthentication no' >/dev/null"
check_remote "sshd disables root login" "sudo sshd -T | grep -Fx 'permitrootlogin no' >/dev/null"
check_remote "sshd restricts login to deploy+admin" "sudo sshd -T | grep -Fx 'allowusers deploy' >/dev/null && sudo sshd -T | grep -Fx 'allowusers admin' >/dev/null"
check_remote "sshd sets ClientAliveCountMax to 3" "sudo sshd -T | grep -Fx 'clientalivecountmax 3' >/dev/null"
check_remote "sshd sets ClientAliveInterval to 300" "sudo sshd -T | grep -Fx 'clientaliveinterval 300' >/dev/null"
check_remote "sshd sets MaxSessions to 2" "sudo sshd -T | grep -Fx 'maxsessions 2' >/dev/null"
check_remote "sshd sets MaxAuthTries to 3" "sudo sshd -T | grep -Fx 'maxauthtries 3' >/dev/null"
check_remote "sshd sets LoginGraceTime to 60" "sudo sshd -T | grep -Fx 'logingracetime 60' >/dev/null"
check_remote "sshd sets LogLevel to INFO" "sudo sshd -T | grep -Fx 'loglevel INFO' >/dev/null"
check_remote "SSH banner points at /etc/issue.net" "sudo sshd -T | grep -Fx 'banner /etc/issue.net' >/dev/null"
check_remote "sshd uses benchmark MACs" "sudo sshd -T | grep -Fx 'macs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com' >/dev/null"
check_remote "SSH hardening drop-in is locked down" "[[ -f /etc/ssh/sshd_config.d/00-vps-scaffold-hardening.conf ]] && [[ \$(stat -c '%a' /etc/ssh/sshd_config.d/00-vps-scaffold-hardening.conf) == '600' ]]"
check_remote "SSH banner file is present" "[[ -f /etc/issue.net ]]"
check_remote "Root password is locked" "sudo passwd -S root | awk '{print \$2}' | grep -qx 'L'"
check_remote "fail2ban is active" "sudo systemctl is-active --quiet fail2ban"
check_remote "fail2ban is enabled" "sudo systemctl is-enabled --quiet fail2ban"
check_remote "auditd is installed" "dpkg -s auditd >/dev/null 2>&1"
check_remote "auditd is active" "sudo systemctl is-active --quiet auditd"

header "Firewall"
check_remote "UFW is active" "sudo ufw status | grep -F 'Status: active' >/dev/null"
check_remote "UFW allows SSH/HTTP/HTTPS" "status=\$(sudo ufw status); [[ \$status == *'22/tcp'* && \$status == *'80/tcp'* && \$status == *'443/tcp'* && \$status == *'443/udp'* ]]"

header "Baseline Hardening"
check_remote "pwquality is installed" "dpkg -s libpam-pwquality >/dev/null 2>&1"
check_remote "apparmor-utils is installed" "dpkg -s apparmor-utils >/dev/null 2>&1"
check_remote "faillock config is present" "[[ -f /etc/security/faillock.conf ]]"
check_remote "faillock config uses expected values" "grep -F 'deny = 4' /etc/security/faillock.conf >/dev/null && grep -F 'fail_interval = 900' /etc/security/faillock.conf >/dev/null && grep -F 'unlock_time = 900' /etc/security/faillock.conf >/dev/null"
check_remote "pam_faillock preauth line is present without inline parameters" "grep -F 'pam_faillock.so preauth silent audit' /etc/pam.d/common-auth >/dev/null && ! grep -E '^auth required pam_faillock\\.so preauth .*?(deny=|fail_interval=|unlock_time=)' /etc/pam.d/common-auth >/dev/null"
check_remote "pam_faillock authfail line is present without inline parameters" "grep -F 'pam_faillock.so authfail audit' /etc/pam.d/common-auth >/dev/null && ! grep -E '^auth \\[default=die\\] pam_faillock\\.so authfail .*?(deny=|fail_interval=|unlock_time=)' /etc/pam.d/common-auth >/dev/null"
check_remote "TMOUT and umask are configured" "grep -F 'umask 027' /etc/profile.d/99-vps-scaffold-session.sh >/dev/null && grep -F 'TMOUT=900' /etc/profile.d/tmout.sh >/dev/null && grep -F 'readonly TMOUT' /etc/profile.d/tmout.sh >/dev/null && grep -F 'export TMOUT' /etc/profile.d/tmout.sh >/dev/null"
check_remote "/etc/profile includes umask" "grep -F 'umask 027' /etc/profile >/dev/null"
check_remote "/etc/bash.bashrc includes umask" "grep -F 'umask 027' /etc/bash.bashrc >/dev/null"
check_remote "Inactive password lock default is configured" "grep -Fx 'INACTIVE=30' /etc/default/useradd >/dev/null"
check_remote "cron.allow exists" "[[ -f /etc/cron.allow ]]"
check_remote "cron.allow uses crontab group" "[[ \$(stat -c '%G' /etc/cron.allow) == 'crontab' ]]"
check_remote "at.allow exists" "[[ -f /etc/at.allow ]]"
check_remote "sudo logging is configured" "sudo grep -F 'Defaults logfile=\"/var/log/sudo.log\"' /etc/sudoers.d/01-vps-scaffold-logging >/dev/null && sudo grep -F 'Defaults use_pty' /etc/sudoers.d/01-vps-scaffold-logging >/dev/null && sudo grep -F 'Defaults timestamp_timeout=0' /etc/sudoers.d/01-vps-scaffold-logging >/dev/null"
check_remote "timesyncd config is present" "[[ -f /etc/systemd/timesyncd.conf ]]"
check_remote "timesyncd config includes expected NTP servers" "grep -F 'NTP=0.ubuntu.pool.ntp.org 1.ubuntu.pool.ntp.org 2.ubuntu.pool.ntp.org 3.ubuntu.pool.ntp.org' /etc/systemd/timesyncd.conf >/dev/null && grep -F 'FallbackNTP=ntp.ubuntu.com' /etc/systemd/timesyncd.conf >/dev/null"

if ! "$SKIP_BACKUP"; then
  header "Backups"

  if remote "[[ -f /opt/backup/backup.sh || -f /etc/systemd/system/backup.service || -d /etc/restic ]]" >/dev/null 2>/dev/null; then
    pass "Backup system is deployed"
    check_remote "backup.sh is installed" "sudo test -x /opt/backup/backup.sh"
    check_remote "restore.sh is installed" "sudo test -x /opt/backup/restore.sh"
    check_remote "restic is installed" "restic version >/dev/null"
    check_remote "/etc/restic/config.env is present and locked down" "sudo test -f /etc/restic/config.env && [[ \$(sudo stat -c '%U:%G:%a' /etc/restic/config.env) == 'root:root:600' ]]"
    check_remote "backup.timer is active" "sudo systemctl is-active --quiet backup.timer"
    check_remote "backup.timer is enabled" "sudo systemctl is-enabled --quiet backup.timer"
    check_remote "backup-verify.timer is active" "sudo systemctl is-active --quiet backup-verify.timer"
    check_remote "backup-verify.timer is enabled" "sudo systemctl is-enabled --quiet backup-verify.timer"

    service_count="$(remote "sudo find /etc/restic/services -maxdepth 1 -type f -name '*.env' | wc -l | tr -d ' '" 2>/dev/null || echo 0)"
    if [[ "$service_count" =~ ^[0-9]+$ ]] && (( service_count > 0 )); then
      pass "Backup service configs exist ($service_count)"
      check_remote "backup.sh dry-run succeeds" "sudo /opt/backup/backup.sh --dry-run >/dev/null"
    else
      if "$REQUIRE_BACKUP"; then
        fail "Backup service configs exist"
      else
        warn "Backup is deployed but no /etc/restic/services/*.env files exist yet; skipped backup.sh dry-run"
      fi
    fi
  else
    if "$REQUIRE_BACKUP"; then
      fail "Backup system is deployed"
    else
      warn "Backup system not deployed yet; rerun with --require-backup after ansible/backup.yml"
    fi
  fi
fi

header "Monitoring & Alerting"
# These layers the roles deploy but the box can technically run without; a prod
# host should not. WARN by default, FAIL under --strict.
check_soft "Deadman heartbeat timer is active" "sudo systemctl is-active --quiet vps-deadman.timer"
check_soft "Deadman heartbeat timer is enabled" "sudo systemctl is-enabled --quiet vps-deadman.timer"
check_soft "Notify config present and locked down (600)" "sudo test -f /etc/vps-scaffold/notify.env && [[ \$(sudo stat -c '%a' /etc/vps-scaffold/notify.env) == '600' ]]"
check_soft "Notify channel is configured (ntfy URL/token set)" "sudo grep -qE '^[[:space:]]*(NTFY_URL|NTFY_TOKEN)=.+' /etc/vps-scaffold/notify.env"
check_soft "Notify self-test timer is active" "sudo systemctl is-active --quiet vps-notify-selftest.timer"
check_soft "Off-host log export timer is active" "sudo systemctl is-active --quiet log-export.timer"
check_soft "Off-host log export timer is enabled" "sudo systemctl is-enabled --quiet log-export.timer"
check_soft "Vulnerability scan timer is active" "sudo systemctl is-active --quiet vuln-scan.timer"
check_soft "AIDE daily integrity check timer is active" "sudo systemctl is-active --quiet dailyaidecheck.timer"
check_soft "unattended-upgrades is enabled" "systemctl is-enabled --quiet unattended-upgrades"

header "Recovery bundle"
# A rebuild needs the not-in-git secrets. make-recovery-bundle.sh drops a
# timestamp marker on success; flag it missing, or stale when any captured
# secret (.env / apps/*/.env / restic config) is newer than the last bundle.
bundle_state="$(remote 'm=/opt/deploy/.recovery-bundle-last; if [ ! -f "$m" ]; then echo MISSING; else n=$( { find /opt/deploy/.env /opt/deploy/apps -type f -name ".env" -newer "$m"; sudo find /etc/restic -type f -name "*.env" -newer "$m"; } 2>/dev/null | head -1 ); [ -n "$n" ] && echo STALE || echo OK; fi' 2>/dev/null || echo ERROR)"
bundle_when="$(remote 'cat /opt/deploy/.recovery-bundle-last 2>/dev/null' 2>/dev/null || true)"
case "$bundle_state" in
  OK)
    pass "Recovery bundle recorded and current (${bundle_when:-unknown})"
    ;;
  STALE)
    soft_note "Recovery bundle is STALE — a secret changed since it was last made (${bundle_when:-unknown}); re-run 'ssh $HOST_ALIAS \"cd /opt/deploy && sudo scripts/make-recovery-bundle.sh\"'"
    ;;
  MISSING)
    soft_note "No recovery bundle recorded — run 'ssh $HOST_ALIAS \"cd /opt/deploy && sudo scripts/make-recovery-bundle.sh\"' and store it offsite"
    ;;
  *)
    soft_note "Recovery bundle status could not be determined"
    ;;
esac

header "Summary"
echo "Pass: $PASS_COUNT"
echo "Warn: $WARN_COUNT"
echo "Fail: $FAIL_COUNT"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
