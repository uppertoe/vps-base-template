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

## 2026-11-02: Open paths beside a gate must be declared; the access-log filter covers percent-encoded tokens and Location

**What lands automatically on the next render and deploy:**

- The Caddy route renderer requires a marker on every open path of a gated
  site. Inside a site that has a guard, a `handle`, `handle_path` or `route`
  block that serves something itself (`reverse_proxy`, `file_server` or
  `respond`) must be guarded or carry
  `# scaffold-lint: open-path -- <paths>: <reason>` inside the block or on the
  comment line above it. The marker becomes a `public` row in
  `route-access.tsv`, so the auth service's "who can reach what" table shows a
  public QR view, a webhook, a calendar feed or an office-network door beside
  the gate it sits next to. See `docs/04-server-repo.md`.
- The access-log token filter also recognises a token whose delimiters are
  percent-encoded (the login redirect carries the asked-for URL inside its
  `rd=` value) and is applied to the `Location` response header. The change
  is in the per-site log block the renderer stamps and in the default logger
  block `run-caddy.sh` assembles; nothing to configure.

**Operator actions:**

1. Before bumping the pointer, run the renderer in the server repo
   (`bash scaffold/docker/render-caddy-routes.sh`) and add the marker to each
   block it reports, then commit the re-rendered `.generated/caddy`. A site
   that already carries `# scaffold-lint: public` for a path inside its block
   can replace that line with the `open-path` marker, which carries the paths
   as well as the reason.

---

## 2026-10-11 — Deploy wrapper executes only the verified HEAD; off-host Caddy logs; audit rules load at boot

**What lands automatically on the next `site-quick.yml`:**

- `vps-deploy` refuses to deploy unless the checkout is on `deploy_branch`
  (default `main`) tracking `origin/<branch>`, every tracked file matches HEAD
  (a dirty `scaffold` submodule counts), no compose override file is present,
  and every `apps/*/deploy.sh` is tracked. Other untracked files (an operator's
  `.bak` copy of an env file) stay allowed. With `deploy_verify_signature`,
  the signature check now runs as root against root-owned configuration only;
  the web-flow key is fingerprint-pinned and imported into
  `/etc/vps-scaffold/gnupg`.
- `log-export.sh` resolves a `/var/lib/docker/volumes/<name>/_data` entry by
  volume-name suffix when the literal path does not exist (compose prefixes
  volume names with the project, so `caddy_logs` is `deploy_caddy_logs`) and
  records every entry's outcome in the archive's `files/EXTRA_PATHS.txt`.
  Until now the Caddy access logs were silently absent from the off-host
  record on every compose-managed host.
- `99-vps-scaffold.rules` no longer watches `/run/containerd/containerd.sock`,
  which aborted `augenrules --load` at boot and dropped every later rule
  (the CIS L2 set and the `-e 2` immutable flag).
- `vps-scaffold-docker-firewall.service` and `vps-cryptswap-swapon.service`
  page via `OnFailure`; the firewall script now fails when the `DOCKER-USER`
  chain is missing instead of reporting success.
- The deploy-trigger config task is `no_log`.
- The Caddy route renderer fails on a brace inside a comment, on unbalanced
  braces, and on any site-block `reverse_proxy` to an app upstream that does
  not strip the gateway session cookie (`import strip_auth_cookie`); a
  deliberate exception is declared with `# scaffold-lint: allow-session-cookie`
  on the preceding line.

**Operator actions:**

1. Before bumping the pointer, run the renderer in the server repo and fix any
   `reverse_proxy` it reports; the fix is a block with
   `import strip_auth_cookie` (see the instance template's `apps/*/*.caddy`).
2. If a deploy fails with "working tree differs from HEAD", the box has local
   edits: inspect with `sudo -u deploy git -C /opt/deploy status`, then either
   land them through git or discard them (`git checkout -- <file>`).
3. On an L2 host, after the next reboot confirm `sudo auditctl -s` reports
   `enabled 2` and `sudo auditctl -l | wc -l` is in the hundreds.
4. After the next nightly export, confirm the journal for `log-export.service`
   shows the `caddy_logs` entry resolving to the project-prefixed volume.
5. Optional tidy-up: the deploy user's keyring copy of the web-flow key
   (`~deploy/.gnupg`) is no longer read and may be removed.

---

## 2026-07-04 — Hands-off update fast path

**What lands automatically on the next `site-quick.yml`:** the
`auto-deploy` and `scaffold-drift` timers (installed but auto-deploy is
opt-in), and Renovate automerge rules for digest-class updates in both
repos' `renovate.json5`.

**The model:** Renovate proposes digest/submodule bumps → repo CI validates →
Renovate automerges on green → the daily `auto-deploy.timer` applies the
result on the box (announced via ntfy; failures alert). Only the
compose/Caddy layer flows this way. Ansible-layer scaffold changes still
require an operator (they carry the actions in this file) — the weekly
`scaffold-drift.timer` alerts when any are waiting.

**Operator actions:**

1. Enable the fast path per host: `deploy_auto_update=true` in
   `ansible/hosts`, re-run `site-quick.yml`.
2. Install the Mend Renovate app on your server repo (and the scaffold, if
   you fork it) — automerge does nothing until Renovate is opening PRs.
3. First run by hand to see the loop end-to-end:
   `sudo systemctl start auto-deploy.service` (no-op when already current).

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
