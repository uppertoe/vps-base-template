# Upgrading an existing instance

Server repos pin this scaffold as a git submodule. Renovate bumps the pointer
and the automatic deploy ships the compose and Caddy parts of a change; the
host layer (roles, timers, scripts) changes only when an operator re-runs the
site play. The mechanics are always the same (docs/12); what varies is the
*operator actions* that accompany a given range of scaffold changes — that's
what this file records.

## How to upgrade

1. Note your current pointer date: `git -C scaffold log -1 --format=%cs`
2. Bump the pointer, unless Renovate already has. By hand:
   `git -C scaffold fetch && git -C scaffold checkout <commit>`, then
   `bash scaffold/scripts/server/check-server-files.sh --fix` and
   `bash scaffold/docker/render-caddy-routes.sh`, review `git status`, and
   commit `scaffold`, `scripts`, `.github`, `.gitignore`, `.generated` and
   any other file the check wrote (`git add -A`). CI fails on drift if the
   workflow callers or the rendered routes do not match the new commit
   (docs/14 "Bumping the pointer").
3. **Read every entry below dated after your old pointer** and collect the
   operator actions.
4. Re-run the site play (`site-quick.yml`, or `site-first-run.yml` when an
   entry says so), then the entry-specific actions. On a restricted-mode
   server the inventory connects as `admin`; the deploy account cannot run a
   site play.
5. Re-baseline evidence: `ansible-playbook -i ansible/hosts
   scaffold/ansible/audit-all.yml`, and acknowledge the expected AIDE delta
   (`sudo aide-rebaseline` records the diff to the journal first).

Entries are newest-first. Skipping several versions is fine — apply the union
of the actions, once.

---

## 2026-11-06 — A failed probe set rolls the deploy back when no hook ran

Under the release tree, `vps-deploy` now undoes a deploy whose acceptance
probes fail, provided the deploy ran no `apps/*/deploy.sh` hook. It switches
`/opt/deploy` back to the previous release, brings it up, runs the probes
against it, records it as the deployed commit and holds the failed commit, so
the hourly `auto-deploy` does not bring that commit straight back. One alert,
`Deploy probes failed: rolled back to <commit>`, names the failing hosts,
says that the previous release is live again and whether its probes passed,
and ends with how to resume: automatic deploys skip the failed commit until a
new commit reaches the branch, and `sudo vps-release unhold` lets them deploy
the same commit again once the cause has been fixed outside the repo. The
deploy still exits non-zero, so `auto-deploy` records the failure as before.

A deploy that ran a hook is never rolled back automatically, because a
migration may have changed data the previous release cannot read; it stays
live, and the alert gives the hook as the reason. The checkout layout
(default-mode servers) stays alert-only as well, and its alert says that
automatic rollback needs the release tree. docs/15 "Automatic rollback" and
docs/05 "Acceptance probes" have the detail.

**Operator actions:** none. The behaviour arrives with the site play that
installs the new wrapper and writes `PROBE_ROLLBACK=1` to
`/etc/vps-scaffold/release.env`. A server that should keep every failed
deploy live sets `deploy_probe_rollback: false` in its inventory before that
play. After an automatic rollback, fix the cause and push; if the cause was
outside the repo and the same commit should go out again, run
`sudo vps-release unhold` and the next `auto-deploy` run deploys it.

---

## 2026-11-04 — Deploys end with acceptance probes against the local Caddy

After `docker compose up --wait` has reported the containers healthy, both
deploy entrypoints (`vps-deploy`, and the default-mode `./deploy`) now run
`vps-deploy-probes`. It reads the release's `.generated/caddy/route-access.tsv`
and asks the local Caddy for the root of every site: a gated site must send
`302` to the gateway's `/login` page, with and without a forged
`Remote-Email` header; a public site must answer below 500 (a root with no route answers 404 by design); nothing may
answer 5xx or fail to answer. A failed probe prints the failing hosts, sends
one `vps-notify` alert, and makes the deploy exit non-zero, so `auto-deploy`
records the failure and its `OnFailure` alert fires. The deploy stays live
and nothing is rolled back; rolling back remains the operator's decision
(`sudo vps-deploy --rollback` under the release tree). docs/05 "Acceptance
probes" has the detail.

**Operator actions:** none beyond the site play that installs the probes. Be
aware of the new failure mode: a deploy can now report failure after its
containers are up and serving. The alert names the hosts; the deploy log
(`journalctl -u auto-deploy`, or the terminal of a hand-run deploy) has each
probe's answer. A site whose DNS the box does not yet serve, so that Caddy
holds no certificate for it, is listed with a reason in `deploy-probes.skip`
at the root of the server repo and committed.

---

## 2026-11-04 — Documentation brought into line with restricted mode, SOPS and the release tree

No code lands with this entry. The docs now describe the platform as it runs:
the rebuild and LTS runbooks say that `restore.sh` and `provision.sh` assume
default mode and a checkout, docs/04 and docs/07 say where a secret is changed
on a SOPS server (`sops` on the laptop, never `.env` on the box), docs/12
says that Renovate bumps the pointer, docs/11 freezes `deploy-trigger.service`
as well as the timer, and the compliance templates cite SOPS, TOTP-on and
restricted mode as the controls.

**Operator actions:**

1. `restore.sh` now stops when the recovered inventory sets
   `deploy_restricted_mode` or `deploy_release_tree`. For a rebuild, set both
   to `false` with `ansible_user=deploy`, complete the drill, then restore
   the settings and run `site-quick.yml` as `admin` (docs/09).
2. In each server repo's `compliance/` pack, re-read control-matrix rows 5,
   16, 24 to 27 and the incident-response recovery section against the
   updated templates, and bring the filled copies up to date.

---

## 2026-11-04 — Ansible corrections from the 2026-11-03 review

**The CIS L2 audit ruleset now follows `baseline_cis_l2_audit_rules`.** The
task that copied `cis-l2-audit.d/*.rules` into `/etc/audit/rules.d/` ran on
every host; it now runs only where the flag is true, and a host with the flag
false (the default) has those files removed on its next site play. Rules
already loaded under the immutable flag (`-e 2`) stay in the kernel until the
host reboots, so such a host keeps auditing setuid executions until then.
Hosts that set the flag true (the RCH and MCH servers) see no change.

**`deploy_restricted_mode` has left the playbook `group_vars/all.yml`.** Its
default of false lives in the deploy-user and docker role defaults, so an
inventory may now set it in `[servers:vars]` as well as per host. A host var
keeps working unchanged. The refusal to narrow deploy's sudo from the deploy
account now reads the account that invoked sudo (`SUDO_USER`), since the
plays gather facts as root.

**The play refuses a string-valued `deploy_allowed_signers` or
`deploy_github_webflow_fingerprints`.** An INI value wrapped in outer single
quotes is read as one string, and the trust store rendered from it refused
every operator-signed deploy (prod-mch-vps, 2026-08-18). Write the list
without outer quotes (docs/05).

**`audit-docker.yml` clones docker-bench-security at a pinned commit** and
passes the trusted docker users derived from the access model; the JSON
report is now fetched from the path the tool writes. Renovate proposes a
pull request when upstream moves; it is not automerged.

**Smaller corrections, no action needed:** `vps-panic-guard-stable.timer` is
templated from `notify_panic_guard_stable_min`; the never-read SSH MACs
drop-in under `sshd_config.d` is removed (the MACs come from devsec's
`ssh_macs` in `sshd_config` itself); the duplicate `INACTIVE=30` task is
gone; the home-directory permission passes run the chmod as the owning
account; the site plays record the scaffold commit from
`/opt/deploy/.release` under the release tree; turning
`host_vm_overcommit_memory_enabled` off removes the sysctl; the log export
takes its "newer than" mark at the start of a run; `vps-deploy` reads
`deploy_verify_signature` through `| bool`. Ports removed from the
`firewall_allowed_*` lists still keep their ufw rules; delete those by hand
(`sudo ufw delete allow <port>/<proto>`).

**Operator actions:**

1. Re-run the site play. On a host without `baseline_cis_l2_audit_rules`,
   reboot in a maintenance window if you want the removed L2 rules out of
   the running kernel.
2. If an inventory carries `deploy_allowed_signers` in outer single quotes,
   remove the quotes before the play (it would otherwise fail with the
   reason).

---

## 2026-11-04 — CI checks what the docs say it checks

From the 2026-11-03 review, batch 3 (docs/14 "The check", docs/08 "Container
CIS Docker §5 controls").

**The workflow callers pass one named secret instead of `secrets: inherit`.**
`check-server-files.sh --fix` rewrites `ci.yml` and `container-security.yml`
as it does on every bump; the callers now pass `GHCR_READ_TOKEN` alone, and
the shared workflows run with the repository's own token where it is not set.

**The compose smoke now checks the CIS Docker section 5 block as declared.**
Every service in the resolved compose config is held to the same controls
and the same `ansible/audit-exceptions.yml` register as `audit-compose.yml`
applies on the host, so a pull request fails where the host audit would have.
A server whose host audit is clean passes unchanged; one with an open finding
sees it in CI from this bump and either fixes the compose file or records
the exception. A service without `user:` fails the non-root control unless
CI has pulled its image; declare `user:` explicitly.

**The route lint treats the site block as the outermost frame.** A
`reverse_proxy`, `file_server` or `respond` written at the top level of a
site whose guard sits only inside a `handle` now needs a guard or an
open-path marker beside it, as a `handle` would. The orchestrator's
`hooks.{$DOMAIN}` site ends in a bare `respond 404` after its guarded and
marked handles; add the marker on the line above it, for example
`# scaffold-lint: open-path -- /*: every other path is answered 404`, then
re-render the bundle and commit `.generated/`.

**The drift check refuses three things `--fix` cannot write.** A
`.gitignore` line below the canonical block that un-ignores a secret path, a
workflow the manifest does not name that runs on `pull_request_target`, and a
`.scaffold-server.yml` value the shared CI cannot act on (anything but
`true`/`false`, a `gateway_ref` that is not a 40-character commit, an unknown
key). Each is reported with the line; correct it by hand.

**Operator actions:**

- Bump the pointer, run `bash scaffold/scripts/server/check-server-files.sh --fix`
  and `bash scaffold/docker/render-caddy-routes.sh`, add the open-path marker
  above any top-level `respond 404` the render reports, and commit.
- No host play is needed for this entry. `vuln-scan.sh` is reinstalled by the
  next `site-quick`; from then on a run in which any image could not be
  scanned exits non-zero (the unit's failure hook notifies) instead of
  reading as clean, and `summary.txt` carries `SCANNED=` and `FAILED=` counts.

---

## 2026-11-04 — Whole files in SOPS: the renderer carries a key or a user list, not only env files

A secrets file whose name does not end in `.env.sops` is now a whole file
(docs/13 "Whole files"): `vps-secrets-render` decrypts it with sops' binary
type and writes it byte for byte to its mirrored path, mode `0600`, below a
subdirectory of its app (`apps/<app>/<dir>/<file>`). The deploy's
world-readable permission pass skips these files, the release tree's bind
check accepts a bind of one, and a rendered whole file whose secrets file has
left the repo is removed at the next render (the record lives in
`/var/lib/vps-secrets-render/`, root-only). A secrets file that would be
rendered over a tracked file is refused by CI, by the wrapper and by
`vps-release`. `check-secrets-encrypted.sh` accepts the binary document.

**Operator actions:**

1. Re-run the site play (`site-quick.yml`) to install the new renderer,
   wrapper and `deploy` script. Nothing changes until a whole-file secret is
   committed.
2. To carry a file this way, encrypt it on the server with
   `sops --encrypt --filename-override secrets/<path>.sops --input-type binary --output-type binary <path>`
   and commit the ciphertext as `secrets/<path>.sops`; the file must not be
   tracked itself. The container that mounts it must run as the rendered
   file's owner (the deploy account in checkout mode, root under the release
   tree), because the file is `0600`.

---

## 2026-11-03 — Restricted mode requires the release tree and the signature gate; the wrapper refuses rewinds

From the 2026-11-03 review (docs/05 "The Repo-to-Root Trust Boundary").

**The site play now refuses `deploy_restricted_mode: true` unless
`deploy_release_tree: true` and `deploy_verify_signature: true` are set.** A
server still on the checkout layout must either adopt the release tree
(docs/15) or set `deploy_restricted_checkout_ok: true` for the transition;
one without the gate must set it up (docs/05) or set
`deploy_restricted_unsigned_ok: true`. The play also refuses to narrow
deploy's sudo while connected as the deploy account, and creates the admin
account before it narrows deploy.

**The deploy account's sudoers allows the bare `vps-deploy` only.** `~/deploy`
is unchanged; `--rollback` and the new `--allow-rewind` are run by the admin
account with `sudo`.

**Rewind guard, both modes:** root records the last deployed commit in
`/var/lib/vps-deploy/last-deployed` and refuses a HEAD that does not descend
from it. A deliberate deploy of an older commit (a revert is the normal
route) needs `sudo vps-deploy --allow-rewind` as admin; `--rollback` is
exempt. The first deploy after the upgrade records without checking.

**Checkout layout hardening** (no action): explicit git directories, a
repository-configuration deny list, no attributes file under `.git`, and
the permission passes run as the deploy account. A checkout whose
`.git/config` sets `core.worktree`, any `filter.*`, `include.*`,
`core.hooksPath` or similar key is refused until the key is removed
(`vps-git config --unset <key>`). `vps-git-heal` no longer passes paths
through `xargs`.

**Operator actions:**

1. Add `deploy_release_tree=true` (after reading docs/15) or
   `deploy_restricted_checkout_ok=true` to each restricted host's inventory
   before the next site play.
2. Re-run the site play.
3. Tell anyone who runs `./deploy --rollback` as deploy that it is now
   `sudo vps-deploy --rollback` as admin.

---

## 2026-11-03 — The recovery bundle retires on SOPS servers; the deploy installs /etc/restic from secrets/backup/

On a server whose repo carries `secrets/recovery.sops`, the smoke test now
passes the recovery check as "held in SOPS", `provision.sh` skips the bundle
stage, and `make-recovery-bundle.sh` does nothing unless `FORCE_BUNDLE=1`.
`restore.sh --from-sops <new-ip>` rebuilds such a server from the repo and
the owner or recovery age key (docs/09). Servers without SOPS keep the bundle
path unchanged.

The renderer (`vps-secrets-render`) now takes `--restic-dir`, and both deploy
paths pass `/etc/restic`: when the repo carries `secrets/backup/config.env.sops`
the rendered backup set is installed there, root-only, and a service file
under `/etc/restic/services/` that the repo no longer names is **removed**, so
a retired service stops being backed up. A repo without `secrets/backup/`
leaves `/etc/restic` alone.

**Operator actions:**

1. Re-run the site play to install the new wrapper and renderer.
2. If the restic configuration is still only on the box, move it into
   `secrets/backup/` (encrypt `/etc/restic/config.env` and each
   `/etc/restic/services/*.env` on the box with `sops` and commit the
   ciphertext; docs/13 "Adopting on a server"). Until then the smoke test
   warns that `/etc/restic` is hand-managed.
3. Before the first deploy after step 2, compare `/etc/restic/services/` with
   `secrets/backup/services/`: any service file missing from the repo is
   deleted by that deploy. Add it to the repo first if it should stay.
4. If `secrets/recovery.sops` still carries a `RESTIC_ETC_TGZ_B64` tarball
   from the interim layout, drop it once `secrets/backup/` is in place.

---

## 2026-11-03 — The release tree (opt-in): root fetches, verifies and exports each deploy

**Nothing changes until you opt in.** With `deploy_release_tree: true` in the
inventory, the next site play installs `vps-release`, copies the read-only
deploy key to `/etc/vps-scaffold/deploy-key`, pins GitHub's host key and
writes `/etc/vps-scaffold/release.env`. The deploy after that exports the
verified commit into `/opt/deploy-releases/<commit>`, renames the old checkout
to `/opt/deploy-legacy` and makes `/opt/deploy` a link to the release. See
`docs/15-release-tree.md`.

**Before opting in:**

1. Every file the running stack reads from `/opt/deploy` must be tracked, and
   no container may write into `/opt/deploy`. The play checks this and lists
   any offending bind mount.
2. In restricted mode, set `deploy_repo_url` and `deploy_verify_signature:
   true` in the inventory; the play refuses the release tree without them,
   because root must not deploy whatever a URL read from the deploy account's
   checkout serves. In default mode, set `deploy_repo_url` if the checkout's
   `origin` is not the server repo's GitHub URL.
3. Move any hand-placed file out of `/opt/deploy` (into SOPS, a volume, or
   elsewhere): a release contains only what git tracks.
4. The read-only deploy key must exist at `/home/deploy/.ssh/github-deploy`
   (`deploy_release_key_source`); the play copies it to
   `/etc/vps-scaffold/deploy-key` for root's fetches.

**After the first release deploy:** `sudo vps-deploy --rollback` as admin
switches back to the previous release; `sudo vps-git log` reads root's
mirror; remove `/opt/deploy-legacy` once the server has deployed cleanly from
releases.

---

## 2026-11-03 — A deploy recreates only what changed

**What lands automatically on the next `site-quick.yml`:** `vps-deploy`,
which every automatic deploy and every restricted-mode or release-tree
`./deploy` runs, no
longer runs `docker compose up --force-recreate` for the whole stack. Compose
recreates a container itself when its image, definition or environment (env
file contents included) changed; the wrapper additionally recreates the
services whose bind-mounted repo files changed in this deploy (the Caddy
bundle and route tables, `sites.yaml`, custom terms, override images), found
from the resolved compose config. A deploy of a small change therefore starts
one or two containers, not twenty, and a slow starter no longer misses its
health deadline because every other app is starting beside it (prod-rch-vps,
2026-11-02, 02:29Z and 22:16Z).

**What to check:** a hook that relied on the full recreate (none known) must
recreate its own service. A file read once at start-up that is NOT
bind-mounted from the repo is unaffected, as before. A hand-run `./deploy` on
a default-mode server in the checkout layout does not go through the wrapper
and still recreates every container.

---

## 2026-11-02 — Digest freshness resolves private images and closes its issue; empty comment lines in secrets

**What to do in each server repo:** `bash scripts/check-server-files.sh --fix`
after the bump; the canonical `digest-freshness.yml` is report-only, opens or
updates a drift issue and closes it when the pins are fresh again, and passes
`GHCR_READ_TOKEN` (or the repo token) so private first-party images resolve. A
server-specific copy is no longer needed for that.

`check-secrets-encrypted.sh` now accepts an empty comment line (`#` alone or
with spaces), which SOPS leaves unencrypted; a comment with content must still
be encrypted.

---

## 2026-11-02 — Server tooling moves into the scaffold; servers keep shims and call reusable workflows

**What to do in each server repo (one-off, after bumping the pointer):**

1. `bash scaffold/scripts/server/check-server-files.sh --fix`. This writes the
   `scripts/` shims over the old script copies, the three workflow callers
   (`ci.yml`, `container-security.yml`, `secret-scan.yml`) pointing at this
   commit, the identical shared files, and seeds `.scaffold-server.yml`.
2. Edit `.scaffold-server.yml`: `gateway_chain`, `gateway_ref`,
   `image_provenance`, `secrets_sops` for this server.
3. Delete `scripts/lib/` (it now lives in `scaffold/scripts/server/lib/`) and
   any server-only copy of a script the manifest names. Keep server-only
   scripts that are not in the manifest.
4. Review `.gitignore`: the canonical block is prepended if it was not present
   verbatim; keep this server's own lines (for example whether `compliance/`
   is tracked) below it.
5. `git add -A && git commit`. CI now runs `check-server-files.sh` first and
   fails on drift.

**What this changes:** `docs/14-server-tooling.md`. The checks themselves are
the union of what the server repos ran: the template's `concurrency` blocks,
the RCH server's gateway suite, provenance step and private-registry login,
and the SOPS encryption check, each switched by `.scaffold-server.yml`.

---

## 2026-11-02 — The renderer sorts in one collation; the deploy wrapper waits for AIDE

**What lands automatically on the next `site-quick.yml`:**

- `vps-deploy` waits for `dailyaidecheck.service` and `aide-rebaseline.service`
  as it already waits for apt and the backup, because containers recreated
  while the AIDE scan holds the CPU miss their health deadline and fail the
  deploy for no fault of their own.
- The "Containers not Up" listing after a failed deploy no longer names
  one-shot init containers that exited cleanly.

**What to do in each server repo:**

- `render-caddy-routes.sh` now sets `LC_ALL=C`, so a render made on a Mac
  matches the one CI makes. Re-render once after bumping the pointer and
  commit `.generated/` if it changes; from then on no `LC_ALL` prefix is
  needed on either machine.

---

## 2026-11-02 — Deploy checks run as root against a copied index; checkout self-heal; web-flow key allow-list

**What lands automatically on the next `site-quick.yml`:**

- `vps-deploy` compares the working tree with HEAD, the `scaffold` submodule
  with the commit HEAD records, and each hook's trackedness, all as root under
  an isolated git configuration and a private copy of the index. The deploy
  account's own git configuration is no longer consulted for any decision, and
  no root-side read writes to the deploy-owned repository.
- `auto-deploy` and `vps-deploy` first run `vps-git-heal`, which hands back to
  the deploy account anything under `/opt/deploy/.git` that a hand-run root git
  left root-owned, and announces the repair over ntfy. A `sudo git status` in
  the checkout therefore no longer blocks the next deploy.
- `vps-git` is installed for administrators: `vps-git <args>` runs git in the
  checkout as the deploy account. Use it instead of `sudo git -C /opt/deploy`.
- The GitHub web-flow trust anchor is now an allow-list of primary
  fingerprints. Only allow-listed keys are imported and any other key already
  in `/etc/vps-scaffold/gnupg` is deleted, which retires GitHub's expired 2017
  key on existing hosts.

**Operator actions:**

- If your inventory sets `deploy_github_webflow_fingerprint` (singular), replace
  it with the list `deploy_github_webflow_fingerprints`. The default lists only
  the fingerprint GitHub publishes for its current web-flow signature,
  `968479A1AFF927E37D1A566BB5690EEEBB952194`.

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

## 2026-11-02 — zram swap tier; a data tier and one ceiling for the whole estate; quieter apt and journal

**What lands automatically on the next `site-quick.yml`:**

- The common role masks `packagekit.service`, empties PackageKit's apt hook
  (`/etc/apt/apt.conf.d/20packagekit`, a conffile dpkg now keeps), disables
  `update-notifier-download.timer`, `update-notifier-motd.timer` and
  `motd-news.timer`, sets `ENABLED=0` in `/etc/default/motd-news`, runs
  `pro config set apt_news=false`, and masks `apt-news.service` and
  `esm-cache.service`. Switches: `common_disable_desktop_apt_hooks` and
  `common_disable_pro_apt_hooks` (set the latter false on a host attached to
  Ubuntu Pro).
- ufw logging is turned off (`host_ufw_logging: "off"`); the exceptions
  register in docs/08 records what is and is not still logged.
- `docker-prune.service` gains a third pass, `docker-prune-unused-tagged`,
  which removes tagged images no container uses, older than the same seven
  day window, by image ID. `docker image prune --all` keeps whatever image
  carries `repo:latest` while a container created from
  `repo:latest@sha256:…` runs (containerd image store), which is how four
  pre-pinning images from June and July outlived every prune.

- The common role installs `systemd-zram-generator` and a `/dev/zram0` swap
  device at priority 100 (half of RAM, capped at 2 GB, zstd). The encrypted
  swapfile stays active as overflow; its own priority becomes 10 at the next
  boot (an already-active swap keeps its old priority until then, and the
  role never swaps a live device off). `swapon --show` should list both.
  Turn it off with `host_swap_zram_enabled: false`; size it with
  `host_swap_zram_size: 768M`.
- The docker role installs `vps.slice` (`MemoryMax=1600M`,
  `MemorySwapMax=1024M`) as the parent of the tiers, a new `vps-data.slice`
  (`900M`, swap allowed) for databases and the apps excepted from the no-swap
  tier, and lowers `vps-noswap.slice` from 1400M to 1100M. The five values
  are `docker_slice_memory_max`, `docker_slice_swap_max`,
  `docker_noswap_memory_max`, `docker_batch_memory_max` and
  `docker_data_memory_max`; the arithmetic is in the role defaults and in
  docs/04 ("Memory tiers").
- `audit-compose.yml` gains `memory_tier`: every long-running container must
  name some `vps*.slice` in `cgroup_parent`, or it is a WARN. Containers that
  sat in `system.slice` until now will fail the audit until the server repo
  places them.

**Operator actions (memory tiers):**

1. In the server repo, give every container that has no `cgroup_parent` one:
   `cgroup_parent: vps-data.slice` for Postgres, Redis and the apps the
   register excepts from `web_no_swap`. Deploy, then run `audit-compose.yml`
   and expect zero `memory_tier` warnings.
2. After the play, confirm the parent cap took effect on the running slice:
   `systemctl show vps.slice -p MemoryMax -p MemorySwapMax` should print the
   configured bytes, not `infinity`. If it still reads `infinity`, apply it
   to the running slice without a reboot with `systemctl set-property
   --runtime vps.slice MemoryMax=1600M MemorySwapMax=1024M`; the unit file
   governs from the next boot regardless.
3. Confirm with `swapon --show` that zram has the higher priority, and expect
   `zramctl` to show pages moving there in preference to the file over the
   following days.

---

## 2026-11-02: Kernel crash record kept in reserved RAM (ramoops), archived and shipped

**What lands automatically on the next `site-quick.yml`:**

- The notify role chooses a 1 MiB region at the top of low RAM from the
  host's `/proc/iomem`, records it in `/etc/vps-scaffold/crash-record.env`,
  reserves it on the kernel command line
  (`/etc/default/grub.d/99-vps-scaffold-crash-record.cfg`, `update-grub`),
  configures the `ramoops` module to keep kernel crash records in it, pins
  `systemd-pstore` to archive those records to `/var/lib/systemd/pstore`, and
  installs `vps-crash-record-check.service`, which reports over ntfy after
  each boot. `kernel.panic_print` is set to 31 by the panic guard so a panic
  prints the task list and memory state. The log export's default
  `EXTRA_PATHS` gains `/var/lib/systemd/pstore`.
- The play refuses with a clear message if the memory map has no suitable
  region; `notify_crash_record_enabled: false` opts out.

**Operator actions:**

- Expect one ntfy message, "Reboot required for crash record". Nothing
  reboots by itself for this. The next patch-window reboot (or your own
  `reboot` in a window) applies the reservation; the boot after it reports
  "Crash record active", and the one after that reports whether the region
  survived the reboot on this hypervisor ("Crash record survives a reboot" or
  "did NOT survive"). If it did not survive, the record cannot be kept on this
  box and a network console is the remaining option; see docs/09.
- Do not test with `echo c > /proc/sysrq-trigger` on a production host. The
  recipe for a throwaway VM is in docs/09 §"The crash record".

---

## 2026-11-02 — Secrets phase 1: age, sops and the server key land on every host

**What lands automatically on the next `site-quick.yml`:** the deploy-user
role installs `age` from the Ubuntu archive, the pinned and checksum-verified
`sops` release (`deploy_secrets_sops_version`, 3.13.3) and
`vps-secrets-render`, creates the server's age key in
`/etc/vps-scaffold/age/` (root `0400`) and prints its public key. Nothing is
decrypted until the server repo carries a `secrets/` directory.

**Operator actions:** none until the server adopts SOPS; the adoption steps
are in docs/13 "Adopting on a server".

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
2. Have Renovate run against your server repo (and the scaffold, if you fork
   it) — automerge does nothing until Renovate is opening PRs. (This entry
   named the Mend app; Renovate has run on the fleet's self-hosted runner
   since 2026-07-11.)
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
8. Optional: have Renovate run against the repo (configs are ready in both
   repos; the fleet's self-hosted runner has replaced the Mend app since);
   the weekly digest-freshness workflow covers drift detection either way.

**Watch-outs:** the encrypted-swap conversion prefers a quiet window; the
journald log-driver change means old `json-file` logs for recreated
containers are no longer readable via `docker logs` (journald has them going
forward); expect one AIDE delta acknowledgment after the upgrade.
