# Security Auditing

> **Start with [08-security-model.md](08-security-model.md)** — it defines which
> benchmark governs each layer (host OS, Docker daemon, containers, images), the
> accepted-exceptions register, and how to interpret each tool for *this* kind of
> host. This page covers *how to run* each tool.

Complementary tools give you confidence that the server is hardened to an
industry standard — not just "custom scripts that seem reasonable":

- **OpenSCAP** — formal CIS Ubuntu 24.04 L1 Server compliance (with a tailoring
  file for accepted cloud exceptions)
- **Lynis** — host hardening-index drift signal
- **docker-bench-security** — CIS Docker Benchmark §1–4 (daemon/host)
- **audit-compose** — CIS Docker Benchmark §5 (per-container runtime)

---

## Lynis — ongoing hardening checks

**What it is:** CISOfy's open-source security auditing tool. Runs on the server
itself, checks the live system state against CIS Benchmark and other standards,
and produces a hardening index score (0-100) with prioritised findings.

**When to run:** After first provisioning, after any significant change, and
periodically (monthly is reasonable for a production server).

```bash
# From this repo directly
ansible-playbook -i ansible/inventory/myserver ansible/audit-lynis.yml

# From a server repo that includes this as scaffold/
ansible-playbook -i ansible/hosts scaffold/ansible/audit-lynis.yml
```

Reports are saved to the repo-root `reports/lynis-<hostname>-<date>/`
directory in either layout.

### Interpreting the score

| Score | Meaning |
|-------|---------|
| < 60 | Significant gaps — review findings before going live |
| 60–75 | Reasonable baseline — work through suggestions |
| 75–85 | Good hardening — realistic target for a public web server |
| > 85 | Strong hardening — remaining findings are often intentional trade-offs |

A score of ~80 is a realistic and respectable target. Running a public web
server means ports 80 and 443 are open, which Lynis will flag — that's expected
and correct for our use case.

### Reading the report

```bash
# View all warnings (should be addressed)
grep 'warning' reports/lynis-myserver-*/report.dat

# View suggestions (lower priority improvements)
grep 'suggestion' reports/lynis-myserver-*/report.dat

# Look up a specific test ID on Lynis's control reference
# https://cisofy.com/lynis/controls/<TEST-ID>
```

---

## OpenSCAP — formal CIS Benchmark compliance

**What it is:** Implements NIST's SCAP (Security Content Automation Protocol)
standard. The `scap-security-guide` package provides official CIS Benchmark
profiles for Ubuntu and Debian. Produces XCCDF reports — the format accepted
by security auditors and compliance frameworks.

**When to run:** When you need to demonstrate formal compliance (e.g. for a
client, an internal audit, or a regulated environment). Also useful for a
detailed breakdown of exactly which CIS controls pass and fail.

```bash
# From this repo directly
ansible-playbook -i ansible/inventory/myserver ansible/audit-openscap.yml

# From a server repo that includes this as scaffold/
ansible-playbook -i ansible/hosts scaffold/ansible/audit-openscap.yml
```

Reports are saved to the repo-root `reports/openscap-<hostname>-<date>/`
directory in either layout.
Open
`report.html` in a browser for a readable pass/fail view of every CIS rule.

The playbook defaults to `openscap_content_source=auto`:
- use the distro-packaged datastream when there is an exact match
- otherwise resolve the latest upstream ComplianceAsCode release archive,
  extract the matching datastream, and cache its URL/checksum metadata in
  `reports/openscap-source.json`

Once that metadata file exists, later runs reuse it so the audit stays
reproducible unless you deliberately refresh it.

If you want to bypass packaged content and force the cached upstream path
immediately:

```bash
ansible-playbook -i ansible/hosts scaffold/ansible/audit-openscap.yml \
  -e "openscap_content_source=upstream"
```

To deliberately refresh the pinned upstream source metadata:

```bash
ansible-playbook -i ansible/hosts scaffold/ansible/audit-openscap.yml \
  -e "openscap_refresh_upstream_content=true"
```

That keeps the default path conservative while still giving you a reproducible,
first-run-discovered upstream fallback when packaged content is behind.

### Profiles

The playbook defaults to **CIS Level 1 Server** — the practical baseline for
servers. Level 2 is stricter and appropriate for high-security environments.

| Profile | Use case |
|---------|----------|
| `cis_level1_server` | Recommended baseline (default) |
| `cis_level2_server` | High-security environments |
| `stig` | US government / DISA compliance |

To change profile, set the variable at run time:

```bash
ansible-playbook -i ansible/inventory/myserver ansible/audit-openscap.yml \
  -e "openscap_profile=xccdf_org.ssgproject.content_profile_cis_level2_server"
```

### Interpreting failures

Not every failed rule is a problem. Some CIS controls conflict with running a
public web server. Common intentional failures to understand and document:

| CIS Control | Why we may not apply it |
|-------------|------------------------|
| Disable IPv6 | May be required by your hosting provider or future tooling |
| Restrict `su` to wheel group | Our deploy user uses sudo, not su |
| Audit framework (auditd) | Not installed by default — consider adding if compliance requires it |
| `/tmp` on separate partition | Requires partitioning at VPS creation time |

For each failure, decide: fix it, accept the risk (and document why), or note
it as a known trade-off. The HTML report includes the rationale for each rule.

### Audit Mapping For This Scaffold

The most useful way to read the OpenSCAP and Docker Bench reports is to map
each warning to one of three buckets: enforced by the scaffold, enabled via an
explicit maintenance run, or accepted as an intentional exception.

| Audit finding | What the scanner is looking for | Scaffold response |
|---------------|---------------------------------|------------------|
| `aide_build_database` | A built AIDE database present on disk | Run `site-first-run.yml` during a maintenance window |
| `file_permission_user_init_files` | User init files at mode `0740` or stricter | Enforced by `baseline-hardening` on each real-host run |
| `all_apparmor_profiles_in_enforce_complain_mode` | AppArmor profiles loaded in `enforce` or `complain` mode | Enforced by `baseline-hardening` on real hosts |
| `sysctl_net_ipv4_conf_*_log_martians` | Runtime + persistent sysctls set to `1` | Enforced via `baseline_host_sysctls` |
| `sysctl_net_ipv4_conf_*_rp_filter` | Runtime + persistent sysctls set to `1` | Enforced via `baseline_host_sysctls` |
| `set_ufw_default_rule` | Default incoming deny policy | Enforced by the firewall role |
| `set_ufw_loopback_traffic` | Explicit loopback allow + spoofed loopback deny | Enforced by the firewall role |
| `ufw_rules_for_open_ports` | Rules for every open non-loopback port | Enforced by the firewall role, plus Docker-aware `DOCKER-USER` filtering for published container ports |
| Docker Bench `1.1.3`–`1.1.18` | Audit watches on Docker/containerd files, sockets, and service units | Enforced by `baseline-hardening` using the exact host paths Docker Bench flags |
| Docker Bench `2.2` | Restricted traffic between containers on the default bridge | Enforced with Docker daemon `icc: false` |
| Docker Bench `2.16` | `userland-proxy` disabled | Enforced with Docker daemon `userland-proxy: false` |

**Intentional exceptions are tracked in the
[exceptions register in 08-security-model.md](08-security-model.md#exceptions-register)**
— the single source of truth, kept in lock-step with the OpenSCAP tailoring file
(`ansible/files/openscap/ssg-ubuntu2404-tailoring.xml`). It covers the
separate-partition mount options and GRUB passwords (deselected as cloud-N/A), plus
public-web-server and Docker exceptions (`ip_forward`, UFW-over-nftables, the
`deploy` user in the `docker` group, ports 80/443, and Caddy's single retained
capability).

> Note: `/tmp` and `/var/tmp` are no longer exceptions — the `os-hardening` role now
> mounts them as size-capped tmpfs with `nodev,nosuid,noexec`, so the corresponding
> CIS rules pass.

### Full Compliance Run

Use the explicit first-run/compliance playbook for the stronger baseline before auditing:

```bash
ansible-playbook -i ansible/hosts scaffold/ansible/site-first-run.yml
```

That gives OpenSCAP the AIDE state it expects while keeping day-to-day runs
faster.

---

## Important: run against a real VPS, not Molecule

Both tools check kernel parameters, mount options, running services, and other
host-level state. Inside a Docker container these checks either fail, report
incorrect values, or are skipped entirely.

**Molecule** validates that the Ansible roles apply correctly to the OS.
**Lynis/OpenSCAP** validates that the resulting system meets security standards.
They're complementary — both are necessary, neither replaces the other.

---

## Docker CIS Benchmark — docker-bench-security

Docker's own official audit tool. Runs the CIS Docker Benchmark controls
against your live daemon and containers.

```bash
# From this repo directly
ansible-playbook -i ansible/inventory/myserver ansible/audit-docker.yml

# From a server repo that includes this as scaffold/
ansible-playbook -i ansible/hosts scaffold/ansible/audit-docker.yml
```

Each output line references a CIS Docker Benchmark section number directly.

The scaffold intentionally focuses on the host and daemon controls that can be
applied safely across many Dockerised apps:
- daemon defaults like `icc: false`, `no-new-privileges`, `live-restore`, and
  `userland-proxy: false`
- auditd watches for the host paths Docker Bench checks explicitly
- Docker-aware filtering for published ports via `DOCKER-USER`

Container-specific controls such as non-root users, CPU limits, read-only root
filesystems, and service-level health checks live in each server repo's
`docker-compose.yml` — and are verified by `audit-compose.yml` below.

---

## Container runtime — audit-compose (CIS Docker §5)

`docker-bench-security` checks the daemon (§1–4) but not the per-container runtime
controls the compose files declare. `audit-compose.yml` closes that gap: it
inspects the running stack and fails if any container is missing a required §5
control (non-root user, `cap_drop: ALL`, `no-new-privileges`, read-only rootfs,
memory/pids limits, healthcheck).

```bash
# Run against the real VPS with the production stack up
ansible-playbook -i ansible/inventory/myserver ansible/audit-compose.yml
```

Findings map to the app's `docker-compose.yml` (see
[04-server-repo.md](04-server-repo.md) for the §5 block). Accept a control with
`audit_compose_exceptions` and record it in
[08-security-model.md](08-security-model.md). The same controls are linted in CI
(KICS) and verified against the live caddy in the server repo's compose smoke test.

---

## Image CVEs — audit-vuln (Trivy) and the daily vuln-scan timer

The CIS tools check *configuration*; they never look at the packages inside the
images. Two Trivy paths close that gap:

- **`ansible/audit-vuln.yml`** — ad-hoc scan of every image actually running on
  the VPS, artifacts fetched to `reports/vuln-<host>-<date>/`.
- **`vuln-scan.timer`** (installed by the `vuln-scan` role, daily) — the same
  scan on-host, with dated evidence accumulating under `/var/lib/vuln-scan/`
  and an urgent ntfy push when a CRITICAL CVE **with an available fix** is
  present. Daily scanning of internet-facing services is the Essential Eight
  ML1 / ISM cadence, and the alert starts the 48-hour patch clock.

Both are report-only — an unfixable upstream CVE must never block operations.
The `common` role's `pending-security-updates.timer` is the OS-package
counterpart: a daily `PATCH-SLA` journal line, plus an alert if security
updates sit unapplied despite unattended-upgrades.

```bash
# Ad-hoc, with artifacts fetched into reports/
ansible-playbook -i ansible/inventory/myserver ansible/audit-vuln.yml

# Evidence trail on the host
ssh <host> 'ls /var/lib/vuln-scan/ && cat /var/lib/vuln-scan/$(date -u +%F)/summary.txt'
journalctl -u pending-security-updates --grep PATCH-SLA
```

---

## Backups that provably restore — restore-drill.timer

`backup-verify.timer` proves the repository is *intact*; the restore drill
proves it *restores*. `restore-drill.sh` (installed by the `backup` role,
monthly by default) restores the latest snapshot of every service into a
throwaway target — DB services through the real `restore.sh` path into a
`<db>_drill` database that is then dropped, files-only services into a scratch
directory — and appends a dated report to `/var/lib/backup-drill/` recording
the snapshot id, achieved **RPO** (snapshot age; fails if older than 26 h by
default) and achieved **RTO** (restore duration). Any failure fires the
`OnFailure=notify@` push.

```bash
# On demand (all services, or one)
ssh <host> 'sudo /opt/backup/restore-drill.sh'
ssh <host> 'sudo /opt/backup/restore-drill.sh --service myapp'

# Latest evidence
ssh <host> 'cat /var/lib/backup-drill/latest.txt'
```

---

## Manual cross-reference sources

If you want to read the controls rather than just run them:

| Resource | What it is | URL |
|----------|-----------|-----|
| `ansible-lockdown/UBUNTU24-CIS` | 198 CIS controls as Ansible tasks — best human-readable reference for what each control does and how it's implemented | `github.com/ansible-lockdown/UBUNTU24-CIS` |
| `ComplianceAsCode/content` | Source YAML for the OpenSCAP profiles we run — look here to understand what a specific rule ID is checking | `github.com/ComplianceAsCode/content` |
| `dev-sec/cis-docker-benchmark` | CIS Docker Benchmark as InSpec tests — readable control descriptions | `github.com/dev-sec/cis-docker-benchmark` |

The `ansible-lockdown/UBUNTU24-CIS` `defaults/main.yml` is particularly useful:
every control has a variable you can toggle, each tagged with its CIS rule ID.
Compare it against our `group_vars/all.yml` to see what we cover and what we don't.

---

## One command: audit-all.yml (evidence bundle)

`audit-all.yml` produces the full dated evidence pack in one run: host
captures first (swap/crypttab, ufw, AppArmor, effective sshd config, timers,
patch-SLA trail, latest vuln-scan/restore-drill/log-export state — each tagged
with the control-matrix rows it evidences in
`reports/evidence-<host>-<date>/INDEX.md`), then OpenSCAP, Lynis,
docker-bench, the compose audit, and the Trivy scan.

```bash
ansible-playbook -i ansible/inventory/myserver ansible/audit-all.yml

# L2 measurement run
ansible-playbook -i ansible/inventory/myserver ansible/audit-all.yml \
  -e openscap_tailoring_profile=xccdf_org.ssgproject.content_profile_cis_level2_server_cloud_vps
```

Run it before a review or attestation; `reports/<...>-<date>/` plus the
filled-in `docs/templates/` set is the handover pack.

---

## Recommended audit workflow

```bash
# 1. Provision a fresh VPS
ansible-playbook -i ansible/inventory/myserver ansible/bootstrap.yml
ansible-playbook -i ansible/inventory/myserver ansible/site-first-run.yml

# 2. Run Lynis for a quick overall score
ansible-playbook -i ansible/inventory/myserver ansible/audit-lynis.yml

# 3. Run OpenSCAP for formal CIS Benchmark compliance (OS)
ansible-playbook -i ansible/inventory/myserver ansible/audit-openscap.yml

# 4. Run docker-bench-security for Docker CIS Benchmark (daemon, §1-4)
ansible-playbook -i ansible/inventory/myserver ansible/audit-docker.yml

# 5. Run audit-compose for the container runtime controls (§5)
ansible-playbook -i ansible/inventory/myserver ansible/audit-compose.yml

# 6. Fix host-level gaps in inventory vars or Ansible roles
# 7. Fix container-level Docker findings in your app compose files
# 8. Re-apply the fast path
ansible-playbook -i ansible/inventory/myserver ansible/site-quick.yml

# 9. Re-run the audits until findings are resolved or formally accepted
```

### CIS feedback loop

Use this loop for OpenSCAP/CIS findings:

1. Run `site-first-run.yml`.
2. Run `audit-openscap.yml`.
3. Classify each failed rule as:
   expected platform exception, host-hardening gap, or app/container gap.
4. Fix host gaps in Ansible or inventory.
5. Re-run `site-quick.yml`.
6. Re-run `audit-openscap.yml`.
7. Repeat until the remaining failures are intentional and documented.

### Docker feedback loop

Use this loop for Docker CIS findings:

1. Run `audit-docker.yml` against the real VPS.
2. Separate findings into:
   daemon-level controls, host integration controls, and per-container controls.
3. Fix daemon/host controls in scaffold roles and inventory.
4. Fix per-container controls in downstream `apps/*/docker-compose.yml`.
5. Re-run `site-quick.yml` if host settings changed.
6. Redeploy the apps.
7. Re-run `audit-docker.yml`.

### GitHub Actions regression loop

This repo also supports a GitHub Actions regression workflow for the base
scaffold:

1. Start from a fresh `ubuntu-24.04` GitHub-hosted runner.
2. Run `bootstrap.yml`.
3. Run `site-first-run.yml`.
4. Run `audit-openscap.yml` and `audit-docker.yml`.
5. Upload the resulting `reports/` directory as a workflow artifact.
6. Optionally publish the generated report index to GitHub Pages from `main`.

Treat that CI workflow as a regression signal for the scaffold itself, not as a
replacement for auditing a real VPS with the actual downstream app stack.
