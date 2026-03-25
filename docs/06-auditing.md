# Security Auditing

Two complementary tools give you confidence that the server is hardened to an
industry standard — not just "custom scripts that seem reasonable".

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

## Recommended audit workflow

```bash
# 1. Provision a fresh VPS
ansible-playbook -i ansible/inventory/myserver ansible/bootstrap.yml
ansible-playbook -i ansible/inventory/myserver ansible/site.yml

# 2. Run Lynis for a quick overall score
ansible-playbook -i ansible/inventory/myserver ansible/audit-lynis.yml

# 3. Run OpenSCAP for formal CIS Benchmark compliance (OS)
ansible-playbook -i ansible/inventory/myserver ansible/audit-openscap.yml

# 4. Run docker-bench-security for Docker CIS Benchmark
ansible-playbook -i ansible/inventory/myserver ansible/audit-docker.yml

# 5. Review reports, fix unexpected failures, re-run
# 6. Commit a note of the score and date in your server repo
```
