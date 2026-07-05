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
   `backup/config.env` and `backup/services/*.env` (including the **restic
   repository password** — without it the offsite backups are undecryptable).
   Create and refresh it with:

   ```bash
   bash scripts/make-recovery-bundle.sh
   ```

   Store the encrypted bundle somewhere that survives your laptop (cloud
   drive, second machine); store the passphrase in a password manager. Re-run
   after any credential rotation — a stale bundle is a quiet failure.
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

1. Create a fresh VPS at the provider (same Ubuntu LTS). Note the IP.
2. Decrypt the recovery bundle into a fresh clone of the server repo:

   ```bash
   git clone --recurse-submodules <server-repo> && cd <server-repo>
   openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in <bundle> | tar -xzv
   ```

3. Point `ansible/hosts` at the new IP. Provision as on first run
   (`bootstrap.yml`, then `site-first-run.yml` — see docs/03).
4. Deploy the stack: `ssh <host> ./deploy`.
5. Restore app data from restic into the named volumes (the backup role's
   restore path; the restore-drill unit exercises the same mechanism).
6. Cut DNS over to the new IP. Lower TTLs ahead of time if you want a faster
   drill number.
7. Verify: post-provision smoke test, `audit-all.yml`, and confirm the
   dead-man's switch and ntfy alerts point at the NEW host.

### RTO log

Keep the honest numbers here — they are the answer to "how long would an
outage last", and the trend tells you when the runbook has rotted.

| Date | Operator | Scenario | Time to serving | Notes |
|------|----------|----------|-----------------|-------|
| —    | —        | first drill pending | — | — |

## Failure modes this covers

- **Provider/region loss** — rebuild at another provider; nothing in the
  repo is provider-specific beyond the inventory IP.
- **Laptop loss** — the bundle is offsite and the passphrase is in the
  password manager; a new laptop bootstraps from GitHub + bundle.
- **Compromise** — same rebuild, but rotate every credential in the bundle
  first and restore data from a snapshot predating the incident (restic
  snapshots are append-only against the Object-Locked bucket).
