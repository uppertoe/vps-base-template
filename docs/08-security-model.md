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
| **Containers (runtime)** | CIS Docker Benchmark **§5** | per-service compose declarations (`caddy.base.yml`, `apps/*/docker-compose.yml`) | `audit-compose.yml` + CI compose-lint (KICS) |
| **Images (supply chain)** | Trivy CVE policy + Dockle best-practice | digest pins + weekly freshness check (Renovate app optional for auto-PRs) | CI (`Trivy`, `Dockle`) |

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

### Public web server & Docker (documented, not deselected)

| Finding | Why accepted |
|---------|--------------|
| Ports 80/443 open; bound to all interfaces (UFW + KICS) | A public reverse proxy must listen publicly. (Docker Bench 5.8, KICS privileged-ports / host-interface.) |
| `net.ipv4.ip_forward=1` | Docker requires IP forwarding. |
| UFW kept instead of nftables | The scaffold uses UFW + Docker-aware `DOCKER-USER` filtering deliberately. |
| `deploy` user in the `docker` group (Docker Bench 1.1.2) | One half of a single accepted risk: **in default mode, `deploy` is root-equivalent** (docker group here + passwordless sudo, see the L2 `sudo_require_authentication` row — same risk, one entry in spirit). Compensating: key-only SSH, single operator, auditd on sudo/docker paths, quarterly access review. **Closure implemented:** `deploy_restricted_mode` (docs/05) removes both grants; flip before any second operator is added. |
| Caddy keeps `cap_add: NET_BIND_SERVICE` | Single retained capability so Caddy binds 80/443 as a non-root user. It still `cap_drop: ALL` first. |

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

Secrets are **file-based by design**: per-app `.env` files (gitignored, forced
to 0600, owner-only), root-owned config under `/etc/restic` and
`/etc/vps-scaffold` (0600). No secrets manager is used — a deliberate call,
not an omission:

| Aspect | Treatment |
|--------|-----------|
| At rest on host | 0600 file perms + single-operator access model (restricted mode confines readers to root/admin); disk-level encryption is the open B1 register item and is the real at-rest control. Encrypted swap prevents paged-out secrets persisting. |
| In containers | Compose `env_file:` puts values in container env, visible to `docker inspect` / `/proc/*/environ`. **Accepted**: only root/admin (and the daemon) can inspect; apps publish no ports and log via journald (no env dumps). Improvement path when images support `*_FILE`: Compose file-based `secrets:`. |
| Change detection | The deploy tree (incl. `.env` files) is AIDE-monitored with content hashing (`DeployConf`); auditd records writes. |
| Off-host / DR | The `env-files` files-only restic service (server template) keeps client-side-encrypted copies; its repository+passphrase pair is the **recovery root**, held in the operator's password manager — the one secret deliberately kept off-box. Backups add no marginal on-box exposure (root already reads the live files) and are ciphertext off-box. Note: rotated secrets persist in old snapshots until retention prunes them — rotation must revoke the credential at its issuer, not merely replace the file. |
| Rotation | Quarterly access review (docs/05): rotate anything unexplained or older than 12 months; app-level secrets (SESSION_SECRET etc.) per their app docs. |
| In-app | The auth service envelope-encrypts reversible secrets (AES-256-GCM) rather than trusting file perms alone; AWS credentials are minted least-privilege per function (backup RW-scoped; log export write-only). |

A secrets manager is re-evaluated when any of: a second operator (per-person
access + audit trail), a second host (central rotation), or an app requiring
dynamic credentials.

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

Then re-add the header comment (XML comments must not contain `--`) and confirm
with `oscap info ssg-ubuntu2404-tailoring.xml`. Add or remove `-u` lines to match
the host-OS exceptions table above.
