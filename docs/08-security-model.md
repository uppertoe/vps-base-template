# Security Model & Evaluation

This document defines **how we evaluate the security of a provisioned VPS** — which
benchmark governs each layer, which tool measures it, and which controls we
deliberately accept as not-applicable. It is the companion to
[06-auditing.md](06-auditing.md), which covers *how to run* each tool.

## What we are protecting

A single, single-tenant **cloud VPS** (~2 GB RAM, single root disk) running
`docker-ce` + a Caddy reverse proxy that fronts a handful of web-app containers.
This is **not** a multi-user enterprise server and **not** bare metal. That shapes
the whole evaluation: the real attack surface is the internet-facing web apps, the
Docker daemon and containers, SSH, and the host OS — in roughly that order. Several
classic CIS controls (separate disk partitions, GRUB console passwords, removable
media) assume hardware and an operating model this host does not have, and are
accepted as exceptions rather than chased.

## The layered model

Each layer has one governing benchmark and one tool that measures it. Nothing is a
"custom script that seems reasonable" — every layer maps to an industry standard.

| Layer | Governing benchmark | Enforced by | Verified by |
|-------|--------------------|-------------|-------------|
| **Host OS** | CIS Ubuntu 24.04 LTS **Level 1 – Server** (v1.0.0) | `os-hardening`, `ssh-hardening`, `baseline-hardening`, `common`, `firewall` roles (devsec.hardening + custom) | `audit-openscap.yml` (OpenSCAP + SSG + tailoring) |
| **Host (2nd opinion)** | Lynis hardening index (not a benchmark — a drift signal) | same roles | `audit-lynis.yml` |
| **Docker daemon / host** | CIS Docker Benchmark **§1–4** | `docker` + `firewall` + `baseline-hardening` roles | `audit-docker.yml` (docker-bench-security) |
| **Containers (runtime)** | CIS Docker Benchmark **§5** | per-service compose declarations (`caddy.base.yml`, `apps/*/docker-compose.yml`) | `audit-compose.yml` + the server repo's compose smoke test; KICS lints the scaffold's own compose files in `compliance-audits.yml` |
| **Images (supply chain)** | Trivy CVE policy + Dockle best-practice | digest pins + weekly freshness check + Renovate bump PRs (self-hosted runner) | server repos: Trivy in the container-security workflow; scaffold: Trivy and Dockle in `compliance-audits.yml` |

### Why these tools, and the version reality

- **OpenSCAP + ComplianceAsCode/SSG** is the standard way to get an
  auditor-recognised, SCAP/XCCDF CIS report for free. **Note:** Ubuntu's
  `ssg-debderived` package ships datastreams only up to `ubuntu2204`, so the audit
  always resolves the **upstream** ComplianceAsCode release for 24.04 (handled
  automatically by `audit-openscap.yml`). SSG currently ships the CIS Ubuntu 24.04
  **v1.0.0** profiles; the CIS catalogue itself has since moved to v2.0.0. Our
  reports therefore measure against **v1.0.0** — defensible, but state it in any
  audit record.
- **Lynis** is actively maintained and useful as a *drift detector / second
  opinion* — not a KPI. A high hardening index means "follows common best
  practice", not "is secure"; it does not test the app surface. Read it
  qualitatively; do not over-harden to chase the number.
- **docker-bench-security** still targets **CIS Docker Benchmark v1.6.0** (current
  is v1.8.0) and only inspects the **daemon/host**. We keep it for §1–4 and accept
  the version lag, but it does **not** verify per-container controls — which is why
  `audit-compose.yml` exists.
- **devsec.hardening** is our *enforcement* baseline, an independent opinionated
  standard — **not** a CIS implementation. Do not assume a high CIS score just
  because the roles ran; reconcile the roles against the OpenSCAP report, which is
  the measurement of record. For a human-readable CIS reference, see
  `ansible-lockdown/UBUNTU24-CIS`.
- **STIG** is out of scope unless a federal/contractual mandate appears.

## Exceptions register

These are the controls we **accept as not applicable or intentional trade-offs**,
with the rationale. The OS exceptions are encoded in the OpenSCAP tailoring file
(`ansible/files/openscap/ssg-ubuntu2404-tailoring.xml`) so they show as
`notselected` in the report rather than as failures. Keep this table and the
tailoring file in lock-step.

### Host OS (deselected in the tailoring file)

| SSG rule(s) | CIS area | Why accepted |
|-------------|----------|--------------|
| `mount_option_var_{nodev,nosuid}`, `mount_option_var_log_{nodev,noexec,nosuid}`, `mount_option_var_log_audit_{nodev,noexec,nosuid}`, `mount_option_home_{nodev,nosuid}` | Separate-partition mount options | A single-disk cloud image has no dedicated `/var`, `/var/log`, `/var/log/audit`, `/home` filesystems; these options cannot be set without repartitioning. CIS's own benchmark text accepts the cloud-resize caveat. |
| `grub2_password`, `grub2_uefi_password` | Bootloader password | No physical/console access on a managed hypervisor; recovery is via the provider console/rebuild. A GRUB password risks locking out provider rescue. |
| `aide_build_database` | AIDE database check | Upstream content bug, not a control gap: the OVAL greps for AIDE 0.17's `database=file:` directive, but Ubuntu 24.04 ships AIDE 0.18.6 which renamed it `database_in=` — unpassable regardless of host state (verified live 2026-07-05). The control itself is met: 34MB database, journalled `aide-rebaseline` pre-checks, daily check timer. Deselected in both profiles; re-select when ComplianceAsCode fixes the regex. |
| `package_nftables_installed`, `service_nftables_disabled`, `set_nftables_base_chain` | Standalone nftables setup | The scaffold's firewall is UFW (an nftables frontend — live nft ruleset active and persistent) with Docker-aware `DOCKER-USER` filtering. The benchmark's standalone-nftables path conflicts with that architecture; same rationale as the L2 `package_ufw_removed` family. Deselected 2026-07-04. |

> **Satisfied, not excepted** (kept selected and driven to *pass* by the roles):
> `account_disable_post_pw_expiration` (INACTIVE=30), `file_permissions_home_directories`
> (0750 on deploy/admin homes), `aide_disable_silentreports`, explicit
> `GSSAPIAuthentication no`, and a `containerd.sock` auditd watch — closed
> 2026-07-04 from the CI rule-level review. Previously noted:
> `/tmp` and `/var/tmp` are size-capped tmpfs (`os-hardening` role) → satisfies
> `partition_for_tmp` + `mount_option_tmp_*` / `mount_option_var_tmp_*`; `/dev/shm`
> is hardened by devsec defaults; `usb-storage` is blacklisted by
> `baseline-hardening`; AIDE is installed, initialised, and its packaged
> `dailyaidecheck.timer` enabled.

### Scanner `error` results (adjudicated, kept selected)

Rules the OpenSCAP probes cannot *evaluate* in this environment — they report
`error`, not `fail`. Kept selected so a future content fix starts scoring them
automatically; adjudicated here so an `error` count in the report is a known
quantity, not an open question. Verified live on the staging host 2026-07-05
(9 errors, all accounted for):

| SSG rule(s) | Why the probe errors | The control itself |
|-------------|----------------------|--------------------|
| `check_ufw_active`, `set_ufw_default_rule`, `set_ufw_loopback_traffic`, `ufw_rules_for_open_ports`, `set_nftables_loopback_traffic`, `set_nftables_table` | The SSG firewall OVAL probes error against a UFW-over-nftables stack rather than evaluating it (same content-architecture mismatch as the deselected standalone-nftables rows above). | **Met and evidenced**: UFW active, default deny in/out, loopback and per-port rules — captured as `firewall.txt` (`ufw status verbose` + `iptables -S`) in every evidence bundle. |
| `file_permissions_unauthorized_world_writable`, `file_permissions_ungroupowned`, `no_files_unowned_by_user` | Whole-filesystem OVAL sweeps that abort in scan context (traversal of container overlay mounts and virtual filesystems). | **Met by construction and spot-checked**: nightly AIDE sweep covers the real filesystem; `find / -xdev` spot-checks in the CI rule-level reviews found no unowned/world-writable files outside documented tmpfs paths. |

| Finding | Why accepted |
|---------|--------------|
| Ports 80/443 open; bound to all interfaces (UFW + KICS) | A public reverse proxy must listen publicly. (Docker Bench 5.8, KICS privileged-ports / host-interface.) |
| `net.ipv4.ip_forward=1` | Docker requires IP forwarding. |
| UFW kept instead of nftables | The scaffold uses UFW + Docker-aware `DOCKER-USER` filtering deliberately. |
| `deploy` user in the `docker` group (Docker Bench 1.1.2), default mode only | One half of a single accepted risk: **in default mode, `deploy` is root-equivalent** (docker group here + passwordless sudo, see the L2 `sudo_require_authentication` row — same risk, one entry in spirit). Compensating: key-only SSH, single operator, auditd on sudo/docker paths, quarterly access review. **Closed on both production servers:** `deploy_restricted_mode` (docs/05) removes both grants and is in force on RCH and MCH; the exception applies only to a server still in default mode, and is to be closed before any second operator is added there. |
| Caddy keeps `cap_add: NET_BIND_SERVICE` | Single retained capability so Caddy binds 80/443 as a non-root user. It still `cap_drop: ALL` first. |
| ufw logging off (`host_ufw_logging`) | Per-packet `[UFW BLOCK]` lines (582 in two hours on a live host, all background internet noise) were the largest single consumer of the journal budget that bounds on-box retention. The rules, their counters (`iptables -nvL`) and the evidence capture (`ufw status verbose`) are unaffected, and fail2ban logs its own bans from sshd. Blocked packets are then recorded nowhere: the auditd rule set does not cover netfilter. Set `"low"` on a host that wants them in the journal and the hourly export. |
| `log_martians` lines from Docker bridges | `net.ipv4.conf.all.log_martians=1` is kept for the benchmark. Containers' gratuitous ARP on the `172.x` bridge networks at start trips it (about 400 lines per boot on a twenty-container host); these are the stack's own interfaces, not spoofed traffic, and are accepted as noise rather than silenced, since the sysctl is per-interface and the bridges are ephemeral. |

### Host OS — CIS Level 2 (deselected in the L2 tailoring profile)

Hosts with `baseline_cis_l2_audit_rules=true` are evaluated against the
`..._cis_level2_server_cloud_vps` tailoring profile. On top of the L1 exceptions
above, the L2 profile deselects the following — each is a deliberate trade-off,
not an unmet control:

| SSG rule(s) | Why accepted |
|-------------|--------------|
| `partition_for_home`, `partition_for_var`, `partition_for_var_log`, `partition_for_var_log_audit`, `partition_for_var_tmp` | Single-root cloud image; separate filesystems need a rebuild/repartition. |
| `package_ufw_removed`, `service_nftables_enabled`, `nftables_rules_permanent` | Host uses UFW, which *is* an nftables frontend (live `nft` ruleset is active and persistent). CIS's standalone-nftables path conflicts with that architecture. |
| `kernel_module_overlayfs_disabled` | `overlay` backs Docker's `overlayfs` storage driver — disabling it breaks Docker. |
| `sysctl_net_ipv4_ip_forward` | Docker requires `ip_forward=1` for container networking. |
| `sudo_require_authentication` | Other half of the deploy root-equivalence risk (see the docker-group row above). Passwordless sudo is needed for unattended Ansible + `~/deploy` in default mode. **Closure implemented:** in `deploy_restricted_mode` the sudoers file becomes a three-line wrapper allowlist and site plays run as `admin`; this exception then applies to `admin` (break-glass) only. |
| `auditd_data_disk_error_action`, `auditd_data_disk_full_action`, `auditd_data_retention_space_left_action`, `auditd_data_retention_admin_space_left_action` | CIS wants `single`/`halt`, which drops a console-less remote VPS offline on a full audit disk (self-DoS). We keep `SUSPEND` + `SYSLOG` and rely on log rotation + monitoring. |

> **Satisfied, not excepted** (driven to *pass* by `baseline_cis_l2_audit_rules`):
> the full CIS L2 audit ruleset (`files/cis-l2-audit.d/`, immutable `-e 2`),
> `audit=1 audit_backlog_limit=8192` grub args, `DisableForwarding yes`,
> `even_deny_root`, AIDE audit-tool monitoring, audispd-plugins, and a
> `privileged.rules` that audits **every** setuid/setgid binary execution.

**OVAL `error` (inconclusive) results — manually verified.** The L2 scan reports
~12 `error` results that the scanner could not evaluate on this host. They are
**not** failures; each underlying control was verified by hand and recorded in
`reports/COMPLIANCE-SUMMARY.md`:

- 7 firewall checks (`set_nftables_*`, `*_ufw_*`) — inconclusive on a UFW-backed
  host; firewall verified active (`ufw status` + live 543-rule `nft` ruleset).
- 3 filesystem-walk checks (world-writable / unowned / ungroup-owned) — error on
  Docker's overlay2 layers; verified 0 offending files outside container storage.
- `all_apparmor_profiles_enforced` — verified 117/117 profiles in enforce mode.
- `audit_rules_privileged_commands` — verified all setuid/setgid binaries audited.

### Regenerating the L2 tailoring profile

The L2 profile lives in the same tailoring file as L1
(`ssg-ubuntu2404-tailoring.xml`); regenerate it with `autotailor` using
`-p ..._cis_level2_server_cloud_vps`, base profile
`..._cis_level2_server`, and one `-u` per L2 rule id in the table above (plus the
two `grub2_*` rules). Audit the host with:

```bash
ansible-playbook -i ansible/hosts scaffold/ansible/audit-openscap.yml \
  -e openscap_tailoring_profile=xccdf_org.ssgproject.content_profile_cis_level2_server_cloud_vps
```

### File integrity (AIDE) — deliberate churn exceptions

| Exception | Why accepted |
|-----------|--------------|
| `/var/lib/*` churn subtrees excluded (docker, containerd, apt, aide, systemd/timers+timesync+random-seed, fail2ban, sudo, logrotate, cloud, ubuntu-advantage, update-notifier, vuln-scan, backup-drill, log-export) | Narrowed from a former blanket `/var/lib` exclusion (which blinded the tripwire to `dpkg/info` maintainer scripts). What remains excluded churns by design on its own timers. The evidence state dirs' integrity anchor is the journal + the **off-host Object-Locked copies** (log-export), not AIDE — the local `hash-chain.log` changes nightly and would be pure alert noise. `dpkg`, `polkit-1` and the rest of `/var/lib/systemd` are now monitored. |
| `~/.bash_history` excluded | Churns on every session and is trivially forgeable; auditd execve records (L2 `privileged.rules`) are the authoritative command trail. `.ssh/authorized_keys`, `.bashrc`, `.profile` stay fully monitored. |
| `/opt/deploy` uses `DeployConf` (Full minus mtime/ctime) | Deploys re-chmod the working tree, bumping ctime with no content change. Content hashes, permissions, owner and inode data — the real tripwire — are retained. |
| Auto re-baseline after apt (`baseline_aide_rebaseline_on_apt`) | apt is treated as the trusted change channel (signed packages); whitelisting `/usr/bin` instead would blind the tripwire to backdoored binaries. **Every re-baseline is preceded by a recorded `aide --check`** whose diff goes to the journal (retained ≥12 months off-host via log-export) and is announced via ntfy — a non-package change slipped in between checks leaves a recorded, alerted trace instead of being silently legitimised. Set `false` for manual-acknowledgement posture. |

### Secrets handling (design position)

On a server that has adopted SOPS ([13-secrets.md](13-secrets.md)), which
every production server has, secrets are kept in the server repo as
age-encrypted files and rendered into the `.env` files at deploy by the
root-run wrapper, root-owned under the release tree. The recovery root is the
offline recovery key together with `secrets/recovery.sops`, which holds the
inventory, and `secrets/backup/`, which holds the restic configuration. No
hosted secrets manager is used: SOPS with age gives a reviewed history of
every change, per-server keys, and a rebuild from the repo and one key, which
is what a manager would have been for at this scale. On a server that has not
adopted SOPS, the per-app `.env` files (gitignored, forced to 0600) and the
`env-files` restic backup remain the arrangement. Root-owned configuration
under `/etc/restic` and `/etc/vps-scaffold` is 0600 in both cases.

| Aspect | Treatment |
|--------|-----------|
| In git | Ciphertext only; CI (`check-secrets-encrypted.sh`, switched by `secrets_sops` in `.scaffold-server.yml`) fails on any plaintext env file or any line left unencrypted. The signed-commit gate covers the secrets as it covers every other file. |
| At rest on host | Rendered files 0600, root-owned in a release; the server's age key is root `0400`. Restricted mode confines readers to root/admin. Disk-level encryption is the open B1 register item and is the real at-rest control. Swap is zram first (compressed pages held in RAM, nothing written) with the random-key encrypted swapfile as overflow, so paged-out secrets never persist. |
| In containers | Compose `env_file:` puts values in container env, visible to `docker inspect` / `/proc/*/environ`. **Accepted**: only root/admin (and the daemon) can inspect; apps publish no ports and log via journald (no env dumps). Improvement path (docs/13 phase 2, not built): Compose file-based `secrets:` where images support `*_FILE`. |
| Change detection | A release never changes after its export; `vps-release verify` (daily timer, `OnFailure` alert) checks the live release, rendered secrets included, against the manifest written when it was prepared, and AIDE leaves `/opt/deploy-releases` alone so a deploy no longer forces a whole-host re-baseline. In the checkout layout the deploy tree including the `.env` files is AIDE-monitored with content hashing (`DeployConf`). auditd records writes in both. |
| Off-host / DR | SOPS server: the repository on GitHub plus the recovery key in the password manager rebuild the box (`restore.sh --from-sops`); the old server key is treated as exposed after a rebuild, because git history keeps ciphertext it can open, so every value is rotated rather than re-encrypted. Server without SOPS: the `env-files` restic service keeps client-side-encrypted copies, and its repository+passphrase pair is the recovery root in the password manager. In both cases rotated secrets persist in old snapshots until retention prunes them, so rotation must revoke the credential at its issuer, not merely replace the file. |
| Rotation | Quarterly access review (docs/05): rotate anything unexplained or older than 12 months; app-level secrets (SESSION_SECRET etc.) per their app docs. |
| In-app | The auth service envelope-encrypts reversible secrets (AES-256-GCM) rather than trusting file perms alone; AWS credentials are minted least-privilege per function (backup RW-scoped; log export write-only). |

A hosted secrets manager is re-evaluated if an app comes to need dynamic
credentials, or if per-person access to secrets is required; the estate
already has several hosts, and SOPS covers them from one owner key.

### Benchmark version lag (watch items)

| Item | Status |
|------|--------|
| CIS Ubuntu 24.04: measured against **v1.0.0** (SSG profiles); CIS catalogue at **v2.0.0** (Jun 2026) | Adopt when ComplianceAsCode ships v2.0.0-aligned profiles; regenerate the tailoring file per the procedure below and re-verify the register. |
| CIS Docker: docker-bench trails catalogue **v1.8.0** (2025) | Adopt when docker-bench-security updates; §5 checks are asserted independently by `audit-compose.yml`. |

### Register verification log

Claims in this register are tied to scans, not intent — record verification
events here:

- **2026-07-02** — full register exercised by the real-VM compliance CI run
  (branch dispatch, then main). Notable: the `/var/tmp` tmpfs "satisfied"
  claim was found to be **false** (devsec silently skips non-mountpoint
  paths) and fixed the same day — the register had overclaimed since the
  entry was written. Lesson: re-verify "satisfied" rows after any change to
  the roles that implement them.
- **2026-11-02** — Swap is zram first with the encrypted file as overflow;
  `vps.slice` caps the whole container estate and `vps-data.slice` holds the
  data tier (`memory_tier` audit control); desktop-era and Ubuntu Pro apt
  hooks masked; ufw logging off and `log_martians` bridge noise accepted
  (rows above); the weekly prune removes unused tagged images by ID.
- **2026-11-03** — Restricted mode on the release tree with the signature
  gate is in force on prod-rch-vps and the MCH server; on those hosts the
  docker-group and `sudo_require_authentication` exceptions no longer apply
  to the deploy account. Secrets are SOPS files rendered at deploy on both,
  and the recovery bundle is retired there.
- **2026-07-03** — AIDE exceptions narrowed (blanket `/var/lib` removed),
  pre-re-baseline recording added, deploy root-equivalence closure
  (`deploy_restricted_mode`) implemented; restricted posture proven by
  molecule; default-mode path proven by real-VM CI.

## Container CIS Docker §5 controls

Every app container must carry the §5 block (see
[04-server-repo.md](04-server-repo.md)). `audit-compose.yml` inspects the running
stack and fails if a non-excepted container is missing any of:

- `5.4` not privileged · `5.3` `cap_drop: ALL` · `5.25` `no-new-privileges`
- `5.12` read-only rootfs · `5.10` memory limit · `5.28` pids limit
- non-root `user:` · `5.26` healthcheck

The daemon also sets `no-new-privileges: true` globally as a backstop, but each
container declares it explicitly so the audit is unambiguous.

Two network assertions ride along with the §5 checks:

- **Per-app proxy isolation** — every Caddy-reachable network must contain
  exactly one app container (the renderer generates one `<app>_proxy` network
  per app; the audit fails if two apps ever share one). This is what makes the
  `Remote-*` identity headers unforgeable from a compromised neighbour app.
- **Database tier separation** (ISM-1269/1270/1271) — database containers
  publish no host ports and sit off all Caddy-reachable networks.

## Container egress policy

Host firewall policy is default-deny outbound with a port allowlist, and
**containers are held to the same allowlist**: the Docker-aware `DOCKER-USER`
chain permits intra-network traffic (Caddy ↔ app), then container-originated
traffic only to the allowlisted outbound ports (22, 53, 80, 443, 587, NTP by
default — `docker_firewall_allowed_outbound_*_ports`), and drops the rest. A
compromised container cannot make arbitrary outbound connections; exfiltration
and C2 are constrained to the same short port list as the host. Widening the
list for a specific app is an inventory-level, reviewable change.

## Unattended updates (change-management position)

Two sanctioned unattended-change channels exist, both modelled on the
`unattended-upgrades` pattern Essential Eight mandates for OS packages:
(1) security patches via unattended-upgrades, and (2) container digest bumps
via Renovate automerge + the `auto-deploy` timer — every change is proposed
by a bot, validated by repo CI (compose smoke, image-pin enforcement,
container security scans), merged only on green, applied at a scheduled
window, announced via ntfy, and reversible via git. The Ansible/OS-config
layer is deliberately excluded from unattended application: those changes
carry UPGRADING.md operator actions and land only when an operator runs the
site play (the `scaffold-drift` timer alerts when any are pending).

## How to read a result

1. **Run the audits** (see [06-auditing.md](06-auditing.md)): `audit-openscap.yml`,
   `audit-docker.yml`, `audit-compose.yml`, `audit-lynis.yml`.
2. **OpenSCAP:** `notselected` = accepted exception (above). `fail` = a real
   residual gap — fix it in a role/inventory, or, if genuinely N/A, add it to the
   tailoring file *and* this register.
3. **Docker §1–4 / §5:** daemon findings → scaffold roles; per-container findings →
   the app's `docker-compose.yml`.
4. **Images:** Trivy HIGH/CRITICAL → bump the digest (freshness issue / Renovate PR) or rebuild;
   report-only in CI so an unfixable upstream CVE does not block deploys.
5. **Lynis:** read qualitatively; investigate large regressions, don't chase 100.

### Regenerating the tailoring file

When SSG ships a newer Ubuntu 24.04 datastream, rebuild the tailoring file with
`autotailor` (package `openscap-utils`) so the deselected rule ids stay valid:

```bash
autotailor \
  -o ansible/files/openscap/ssg-ubuntu2404-tailoring.xml \
  -p xccdf_org.ssgproject.content_profile_cis_level1_server_cloud_vps \
  --title "CIS Ubuntu 24.04 L1 Server - vps-scaffold cloud VPS tailoring" \
  -u xccdf_org.ssgproject.content_rule_mount_option_var_nodev \
  -u xccdf_org.ssgproject.content_rule_mount_option_var_nosuid \
  -u xccdf_org.ssgproject.content_rule_mount_option_var_log_nodev \
  -u xccdf_org.ssgproject.content_rule_mount_option_var_log_noexec \
  -u xccdf_org.ssgproject.content_rule_mount_option_var_log_nosuid \
  -u xccdf_org.ssgproject.content_rule_mount_option_var_log_audit_nodev \
  -u xccdf_org.ssgproject.content_rule_mount_option_var_log_audit_noexec \
  -u xccdf_org.ssgproject.content_rule_mount_option_var_log_audit_nosuid \
  -u xccdf_org.ssgproject.content_rule_mount_option_home_nodev \
  -u xccdf_org.ssgproject.content_rule_mount_option_home_nosuid \
  -u xccdf_org.ssgproject.content_rule_grub2_password \
  -u xccdf_org.ssgproject.content_rule_grub2_uefi_password \
  /path/to/ssg-ubuntu2404-ds.xml \
  xccdf_org.ssgproject.content_profile_cis_level1_server
```

The list above is not complete. The current tailoring file also deselects
`aide_build_database`, the standalone-nftables rules
(`package_nftables_installed`, `service_nftables_disabled`,
`set_nftables_base_chain`), `sysctl_net_ipv4_ip_forward` and
`package_ufw_removed` in the L1 profile, and regenerating from the list above
alone would re-select them, after which the register overclaims. Before
regenerating, list every rule the file deselects and pass one `-u` line for
each:

```bash
grep -o 'idref="[^"]*" selected="false"' ansible/files/openscap/ssg-ubuntu2404-tailoring.xml
```

Then re-add the header comment (XML comments must not contain `--`) and confirm
with `oscap info ssg-ubuntu2404-tailoring.xml`. Add or remove `-u` lines to match
the host-OS exceptions tables above, which the `grep` must agree with.
