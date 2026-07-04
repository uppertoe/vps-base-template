# Upgrading an existing instance

Server repos pin this scaffold as a git submodule, so **nothing changes on a
live VPS until you bump the pointer and re-run the site play**. The mechanics
are always the same; what varies is the *operator actions* that accompany a
given range of scaffold changes — that's what this file records.

## How to upgrade

1. Note your current pointer date: `git -C scaffold log -1 --format=%cs`
2. Bump: `git submodule update --remote --merge scaffold && git add scaffold
   && git commit -m "chore: update scaffold" && git push`
3. **Read every entry below dated after your old pointer** and collect the
   operator actions.
4. Re-run the site play (`site-quick.yml`, or `site-first-run.yml` when an
   entry says so), then the entry-specific actions.
5. Re-baseline evidence: `ansible-playbook -i ansible/hosts
   scaffold/ansible/audit-all.yml`, and acknowledge the expected AIDE delta
   (`sudo aide-rebaseline` records the diff to the journal first).

Entries are newest-first. Skipping several versions is fine — apply the union
of the actions, once.

---

## 2026-07-04 — Victorian health compliance wave

Covers everything merged 2026-07-02 → 2026-07-04 (compliance controls, the
deploy/admin access split, evidence dashboard, CIS/docker findings closure).
An instance built from a June 2026 scaffold gets all of the following on its
next bump.

**What lands automatically on the next `site-quick.yml`:**

- Daily Trivy CVE scan (`vuln-scan.timer`) + daily patch-SLA check; monthly
  backup **restore drill** with RPO/RTO reports (`/var/lib/backup-drill/`)
- **Encrypted swap** (random key per boot). The play converts live; if RAM
  can't absorb the swapped pages it finishes the config and encrypts on the
  next reboot — check `swapon --show` afterwards
- `admin` **break-glass account** (key from `deploy_admin_public_key`,
  defaults to the deploy key) and the root-owned wrapper entrypoints
- AIDE: narrowed `/var/lib` exclusions (dpkg/info now monitored), recorded
  pre-re-baseline checks, re-baseline announcements via ntfy
- auditd suspension alerting; audit rules files normalised to 0600
- **Container logs move to the journald driver** — containers are recreated
  on the next `./deploy`; `docker logs`/`compose logs` still work
- CIS closures: account-expiry lockout (INACTIVE=30), 0750 home dirs, 0740
  user dot files, explicit GSSAPI-off, X11 remnants purged, ETM-only SSH MACs,
  **ECDSA host key no longer offered** (clients prefer ed25519; no
  known_hosts churn expected)

**Operator actions (in order):**

1. `apps/auth/.env` on the server: set `TOTP_ENABLED=true` (template default
   changed; your live gitignored .env does not update itself). Admins enrol
   on next login.
2. Off-host logs (ISM-1988): from your laptop,
   `python3 scripts/aws-logs-setup.py --profile <admin> --bucket <name>
   --iam-user <name>`, paste the printed `log_export_*` vars into
   `ansible/hosts`, re-run `site-quick.yml`, then
   `ssh <host> 'sudo systemctl start log-export.service && sudo tail
   /var/lib/log-export/hash-chain.log'`.
3. Dead-man's switch: create a Gatus external endpoint (or Healthchecks
   check), set `notify_deadman_url` (+ `notify_deadman_token` for Gatus) in
   the inventory. Gatus must alert via a channel independent of this VPS.
4. Secret recovery: `cp backup/services/env-files.env.example
   backup/services/env-files.env`, fill in, run `ansible/backup.yml`, and
   **store that repository+passphrase pair in your password manager** (it is
   the recovery root).
5. First-run the new timers once by hand and eyeball output:
   `sudo systemctl start vuln-scan.service restore-drill.service`.
6. Staged (when ready): flip `deploy_restricted_mode=true` +
   `ansible_user=admin` per the runbook in
   [docs/05-access-model.md](docs/05-access-model.md) — verify admin SSH+sudo
   FIRST. Retires the register's deploy root-equivalence exception.
7. Evidence: copy [docs/templates/](docs/templates/) into the server repo's
   `compliance/` and fill them in; run `audit-all.yml` for the baseline
   bundle; update the docs/08 register verification log with the date.
8. Optional: enable the Mend Renovate app (configs are ready in both repos);
   the weekly digest-freshness workflow covers drift detection either way.

**Watch-outs:** the encrypted-swap conversion prefers a quiet window; the
journald log-driver change means old `json-file` logs for recreated
containers are no longer readable via `docker logs` (journald has them going
forward); expect one AIDE delta acknowledgment after the upgrade.
