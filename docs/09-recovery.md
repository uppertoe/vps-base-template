# Recovery — Rebuilding the Box

The scaffold's backup story (restic + restore drills) proves the **data**
restores. This runbook covers the other half: the **box** is gone — provider
outage, corrupted host, fat-fingered teardown — and you need a serving
replacement. A set-and-forget host earns that name only if this path is
written down and has been walked at least once.

## What a rebuild needs

Three inputs. If you have all three, the box is cattle; missing any one, it's
a pet with no vet.

1. **The server repo** — everything reproducible: hardening, compose files,
   routes, this scaffold. Lives on GitHub; nothing to do.
2. **The recovery bundle** — everything deliberately NOT in git:
   `ansible/hosts` (inventory + tokens), the server `.env`, `apps/*/.env`,
   and the backup credentials (including the **restic repository password** —
   without it the offsite backups are undecryptable). Create and refresh it
   with:

   ```bash
   ssh <host> 'cd /opt/deploy && sudo scripts/make-recovery-bundle.sh'
   ```

   **Run it on the server, with sudo** — that is the only place holding the
   full current set. The live `apps/*/.env` may have been edited only on the
   box, and the restic secrets live in **`/etc/restic/` (root-only), not in the
   deploy checkout** — a laptop-made or non-sudo bundle silently omits the
   restic password, the one irreplaceable secret. The script refuses to write a
   bundle that captured no `RESTIC_PASSWORD` rather than hand you a confident
   dud; `DRY_RUN=1` previews the file list first. Store the encrypted bundle
   somewhere that survives your laptop (a password-manager attachment, a cloud
   drive) and store the passphrase **with it** — split across two places and
   losing either loses everything. Re-run after any credential rotation — a
   stale bundle is a quiet failure.
3. **Out-of-band access** — the DNS registrar login, the VPS provider login,
   and the GitHub account. These live in the password manager, not on the box.

## Provider snapshots (second lane)

Enable the provider's automated snapshots/backups if the plan offers them —
they're near-free and turn "rebuild from scratch" into "roll back" for whole
classes of failure (bad kernel, botched upgrade). Treat them as a convenience
lane only: snapshots live with the same provider account as the VPS, so the
restic offsite repo remains the real backup.

## The rebuild drill

Do this once for real (a throwaway VPS costs cents/hour), record the time,
then repeat roughly **annually** and after any structural change to
provisioning. The point is not the ceremony — it's discovering the missing
step while it's cheap.

1. Create a fresh VPS at the provider (same Ubuntu LTS). Note the IP. Clear
   the stale SSH host key locally: `ssh-keygen -R <ip>`.
2. Decrypt the recovery bundle into a fresh clone of the server repo:

   ```bash
   git clone --recurse-submodules <server-repo> && cd <server-repo>
   openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in <bundle> | tar -xzv
   ```

3. Point `ansible/hosts` at the new IP. Provision as on first run — from a
   provider root password, that is `bootstrap.yml --ask-pass` (creates the
   users + installs your key), then `site-first-run.yml` over the key (full
   hardening; see docs/03). **Run ansible from the repo root with the
   scaffold's transport config**, or the slow/flaky-link resilience does not
   apply: `ANSIBLE_CONFIG=scaffold/ansible/ansible.cfg ansible-playbook …`.
4. **Populate `/opt/deploy` on the server** (site-first-run creates the
   directory but does not clone the repo):

   ```bash
   ssh <host> 'git clone --recurse-submodules <server-repo> /opt/deploy'
   # then place the not-in-git secrets from the decrypted bundle:
   #   .env, apps/*/.env, backup/config.env, backup/services/*.env
   # (scp to /tmp, then install -o deploy -g deploy -m 600 into /opt/deploy)
   ```

5. **Configure backups**: `ansible-playbook -i ansible/hosts ansible/backup.yml`
   — this is a separate play, NOT part of site-first-run; it installs restic
   and `/etc/restic/` from `backup/config.env` + `backup/services/*.env`.
   Confirm the repo is reachable: `ssh <host> 'sudo restic … snapshots'`.
6. Deploy the stack: `ssh <host> ./deploy`.
7. Restore app data from restic into the named volumes where an app has a
   database (the backup role's restore path; the restore-drill unit exercises
   the same mechanism). TLS certs re-issue via ACME; alert history that is not
   backed up (e.g. ntfy) starts empty — expected.
8. Cut DNS over to the new IP. Lower TTLs ahead of time if you want a faster
   drill number.
9. Verify: post-provision smoke test, `audit-all.yml`, and confirm the
   dead-man's switch and ntfy alerts point at the NEW host.

> **Order matters.** The secrets restore (step 4) and backup config (step 5)
> sit *between* provisioning and deploy — a fresh box has neither the repo nor
> restic until you place them. Discovered in the 2026-07-06 drill, which is
> exactly why the drill is mandatory.

### RTO log

Keep the honest numbers here — they are the answer to "how long would an
outage last", and the trend tells you when the runbook has rotted.

| Date | Operator | Scenario | Time to serving | Notes |
|------|----------|----------|-----------------|-------|
| 2026-07-06 | repo owner | Full wipe + rebuild of the live staging box (RackNerd US) from recovery bundle + backups | **~63 min** | Dominated by site-first-run (43 min, CIS L1+L2 over a trans-Pacific link); bootstrap 11, reinstall+ssh 2.5, restore+backup+deploy 7.5. 0 failed tasks. Backup repo reachable from the rebuilt box (restic timer fired mid-drill). Surfaced two runbook gaps (steps 4–5 above) and the ansible.cfg auto-load gap — all fixed in this commit. |

## Failure modes this covers

- **Provider/region loss** — rebuild at another provider; nothing in the
  repo is provider-specific beyond the inventory IP.
- **Laptop loss** — the bundle is offsite and the passphrase is in the
  password manager; a new laptop bootstraps from GitHub + bundle.
- **Compromise** — same rebuild, but rotate every credential in the bundle
  first and restore data from a snapshot predating the incident. Caveat: the
  backup bucket is **versioned, not Object-Locked** (restic prune needs delete
  rights, so the on-box key can delete/overwrite snapshots). If the box's
  credential is suspected compromised, do not trust on-box restic history —
  recover an overwritten/deleted snapshot from the 90-day noncurrent-version
  window using **account-level** (not on-box) credentials, and corroborate the
  timeline against the Object-Locked log bucket. See docs/11 §3.
