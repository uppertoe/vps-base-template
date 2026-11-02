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
   ssh -t <host> 'cd /opt/deploy && sudo scripts/make-recovery-bundle.sh'
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
   stale bundle is a quiet failure. A successful run drops a
   `/opt/deploy/.recovery-bundle-last` marker; `post-provision-smoke-test.sh
   --strict` reports the bundle **missing** or **stale** (a captured secret
   newer than the last bundle) so the gap surfaces at the next evidence pass
   rather than during an outage. Creating the bundle is Step 13 of the
   provisioning runbook (docs/03), not an afterthought.
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

**Fast path — `./restore.sh`:** your server repo ships `scripts/restore.sh`,
which automates steps 1–9 below (everything except creating the VPS and cutting
DNS). From a fresh `git clone --recurse-submodules` of the server repo:

```bash
scripts/restore.sh <recovery-bundle.enc> <new-ip>
scripts/restore.sh --dry-run <recovery-bundle.enc> <new-ip>   # preview
scripts/restore.sh --list <recovery-bundle.enc>               # inspect bundle
```

Two prompts — the bundle passphrase and the new box's root credential — and
it's resumable: re-run the same command after any mid-way failure and completed
stages skip. The annotated manual steps below are the reference, and exactly
what `restore.sh` executes in order (the "order matters" note is why the
orchestrator enforces it).

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

## When the kernel stops rather than the disk

Not every outage needs a rebuild. A panicked or lockup-wedged kernel sits
there indefinitely by default, so a fault lasting seconds becomes an outage
lasting as long as it takes someone to reach the provider panel — that is what
turned a three-second failure into three and a half hours on 2026-09-22.

`vps-panic-guard` gives the box exactly one chance to fix itself. While the
host is believed healthy the kernel is set to reboot on a panic, an oops or a
soft lockup. As soon as that reboot is actually used, the guard disarms: a
second crash before the host has proved itself leaves the machine down and
intact, because a box that reboots on every boot destroys the evidence of why
on each cycle. Thirty minutes of uptime redeems the strike and re-arms it, and
an orderly shutdown (a patch reboot, your own `reboot`) is never counted as a
crash. Both transitions announce themselves over ntfy.

So a single "Auto-reboot disarmed" alert means the host crashed, came back by
itself, and is now deliberately unprotected — treat it as a summons, not as an
all-clear. If the box is still down, **read the console in the provider panel
before rebooting**: while the machine sits at the panic, the console is where
the panic text is. If the box has come back, the crash record below is where
the same text has been kept.

    systemctl status vps-panic-guard           # armed this boot?
    sysctl kernel.panic kernel.panic_on_oops   # 0 means disarmed
    cat /var/lib/vps-notify/panic-guard/strikes

Hung-task panics are on (`notify_panic_guard_on_hung_task`), because that is
the failure actually seen here. On 2026-09-22 prod-rch-vps kept serving cached
pages while every disk write blocked for three and a half hours: nothing
panicked, nothing was logged, and the box had to be reset from the panel.
Tasks stuck in D state past `hung_task_timeout_secs` is precisely that
condition, and it raises a real panic, which the crash record captures and
the guard reboots out of, once. Turn it off only if legitimate I/O on the host
regularly blocks that long.

### The crash record

The panic guard's reboot has a cost: the panic text goes to the console, and
nothing records the console, so ten seconds later the cause is gone. Three
stops between September and November 2026 left no evidence for that reason.
The notify role therefore keeps the record on the box itself. `ramoops` is the
pstore backend that writes the kernel's last messages into a region of RAM
reserved from the kernel's own use (`memmap=` on the command line). A guest's
own reboot does not normally clear its RAM, so the region is still there when
the next kernel starts; `systemd-pstore` copies the records to
`/var/lib/systemd/pstore` early in that boot, the hourly log export ships that
directory to the log bucket, and `vps-crash-record-check` sends "Crash record
captured" over ntfy with the file names and the lines that name the fault.
`kernel.panic_print=31` makes the kernel append the task list and the memory
state to the panic text, so the record is enough to act on.

The region is chosen on the target from `/proc/iomem` (the top 1 MiB of the
highest System RAM range below 4 GiB, aligned to 1 MiB and clear of the kernel
image), written to `/etc/vps-scaffold/crash-record.env`, and kept on later
runs. The reservation only takes effect when the kernel boots with it, and the
play never reboots: it writes the GRUB fragment, runs `update-grub`, records
the pending reboot under `/var/lib/vps-notify/crash-record/` and alerts once
("Reboot required for crash record"). The weekly digest repeats the reminder
until the next patch-window or operator reboot applies it.

**Confirming it after the next reboot.** Three things to check on the box:

    cat /proc/cmdline | tr ' ' '\n' | grep -E 'memmap|pstore|log_buf'
    cat /sys/module/ramoops/parameters/mem_address      # decimal; matches crash-record.env
    cat /sys/module/pstore/parameters/backend           # ramoops
    journalctl -b -k -g ramoops                         # "using 0x100000@0x..." plus the header verdict
    sudo ls -la /sys/fs/pstore /var/lib/systemd/pstore  # empty until a panic

The first boot with the reservation can only report that the region is live
(`vps-crash-record-check` sends "Crash record active" and clears the pending
marker). Whether the region survives a reboot on this hypervisor is proven at
the second boot: the module says `found existing empty buffer` when it finds
the header it wrote last time, and `no valid data in buffer` when the region
came up blank. The check sends one message either way ("Crash record survives
a reboot", or "did NOT survive"), and the second is the signal to stop relying
on the record and reconsider a network console.

**Testing a real panic.** Not on the production box. `kernel.sysrq` is 0
here, and even a controlled panic takes the services down for the reboot and
spends the panic guard's one strike. Test on a throwaway VM instead: a noble
guest under QEMU/KVM or libvirt on a laptop, with the notify role applied (or
the GRUB fragment and `/etc/modprobe.d/vps-scaffold-ramoops.conf` copied in by
hand), rebooted twice so the second boot reports `found existing empty buffer`,
then

    sudo sysctl -w kernel.sysrq=1
    echo c | sudo tee /proc/sysrq-trigger

After the guest comes back, `/var/lib/systemd/pstore/<timestamp>/dmesg.txt`
holds the panic, its backtrace and the task list, and the ntfy message (if the
VM has a token) reads as it would from production. That proves the mechanism;
it does not prove the provider's hypervisor preserves the region, which only
the second-boot verdict above can.

**Reading a captured record.** The alert names the files. On the box:

    sudo ls -R /var/lib/systemd/pstore
    sudo less /var/lib/systemd/pstore/*/dmesg.txt     # or the dmesg-ramoops-N parts

The same files are in the log bucket within the hour under
`<host>/<year>/logs-<host>-<stamp>.tar.zst` (`files/var/lib/systemd/pstore/`),
so the record is readable even if the box is rebuilt. Copy the record off the
box before analysing it at length; parsing on a 2 GB host has wedged it before.
The record is the newest part of the kernel log, so the panic banner and the
`Call Trace` sit before the task list that `panic_print` appends, and a
hung-task panic shows the blocked task twice: once in the watchdog's own report
and again, in D state, in the task list.

**What it cannot do.** A power cycle, a provider-side reset or a host failure
never preserves guest RAM, so those stops still leave only the console. A
hypervisor may also clear guest memory on every reboot; the second-boot
verdict tells you whether this one does. The kernel log buffer is raised to
1 MiB (`log_buf_len=1M`) so the task list does not push the panic message out
of the buffer before it is dumped, and the whole 1 MiB region is dump space
(`pstore.kmsg_bytes` matches it); a panic that needs more than one 256 KiB
record takes several slots, newest first.

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
