# vps-base-template

> Upgrading an existing instance? Read [UPGRADING.md](UPGRADING.md) — it records the operator actions required for each scaffold change.

[![CI](https://github.com/uppertoe/vps-base-template/actions/workflows/ci.yml/badge.svg)](https://github.com/uppertoe/vps-base-template/actions/workflows/ci.yml)

Infrastructure base for hardened VPS instances running Dockerised apps behind
Caddy. Used as a git submodule in per-server repos.

## Two repos, one server

```
vps-base-template/     ← this repo — infrastructure, don't edit per-server
server-[name]/         ← your repo — apps, config, Caddyfile, .env
  └── scaffold/        ← submodule pointing here
```

`vps-base-template` provides the Ansible roles, Caddy base compose, and
Molecule test suite. Your server repo (created from
[server-instance-template](https://github.com/uppertoe/server-instance-template))
provides everything specific to that VPS.

## What this repo provides

| Path | Purpose |
|------|---------|
| `ansible/roles/common` | Base packages, auto-updates, fail2ban, swap (zram + encrypted file), monitoring, earlyoom |
| `ansible/roles/deploy-user` | The deploy and admin accounts, sudoers, the root-owned wrappers (`vps-deploy`, `vps-release`, `vps-secrets-render`), the server's age key |
| `ansible/roles/ssh-hardening` | Hardens sshd (wraps dev-sec.io) |
| `ansible/roles/os-hardening` | Kernel-level hardening (wraps dev-sec.io) |
| `ansible/roles/baseline-hardening` | auditd and its rule sets, AIDE, AppArmor, sysctls, the CIS closures devsec leaves open |
| `ansible/roles/docker` | Docker CE + compose plugin, memory tier slices, weekly prune timer |
| `ansible/roles/firewall` | UFW + Docker-aware filtering for published ports |
| `ansible/roles/backup` | Hourly PostgreSQL → Restic backups + off-hour weekly verification + monthly restore drill |
| `ansible/roles/vuln-scan` | Daily Trivy scan of the running images, with the fixable-CRITICAL alert |
| `ansible/roles/log-export` | Hourly journal, audit and Caddy log export to an Object-Locked bucket |
| `ansible/roles/notify` | ntfy delivery, dead-man's switch, panic guard, crash record, weekly digest |
| `ansible/bootstrap.yml` | Run once as root — creates the deploy and admin users |
| `ansible/site-first-run.yml` | Heavier first-run/compliance pass — includes safe upgrade + AIDE init |
| `ansible/site-quick.yml` | Explicit fast day-to-day apply path |
| `ansible/audit-*.yml` | `audit-all` (the evidence bundle), OpenSCAP, Lynis, docker-bench, `audit-compose` (CIS Docker §5), `audit-vuln` (Trivy) |
| `scripts/` | Repo tooling, the compliance page renderer |
| `docker/caddy.base.yml` | Base Caddy service — included by server repos |
| `scripts/server/`, `server-files/`, `.github/workflows/server-*.yml` | The server repos' CI checks, operator scripts and reusable workflows; servers carry shims kept in step by `check-server-files.sh` (docs/14) |
| `molecule/default/` | Role deployment tests — Ubuntu 24.04 |
| `molecule/backup/` | Backup role deployment test |
| `backup/tests/integration/` | End-to-end backup + restore script tests |

## Creating a server repo

Use [server-instance-template](https://github.com/uppertoe/server-instance-template)
as the starting point for a new server repo. It has this scaffold pre-wired as
a submodule and includes the backup configuration structure.

## Documentation

| Doc | What it covers |
|-----|----------------|
| [docs/01-prerequisites.md](docs/01-prerequisites.md) | SSH keys, Ansible, Python venv setup |
| [docs/02-local-testing.md](docs/02-local-testing.md) | Molecule test suite + backup integration tests |
| [docs/03-provisioning-a-server.md](docs/03-provisioning-a-server.md) | Full provisioning walkthrough |
| [docs/04-server-repo.md](docs/04-server-repo.md) | Server repo structure and conventions |
| [docs/05-access-model.md](docs/05-access-model.md) | The deploy and admin access model, restricted mode, and the repo-to-root trust boundary |
| [docs/06-auditing.md](docs/06-auditing.md) | How to run each audit tool (OpenSCAP, Lynis, docker-bench, audit-compose) |
| [docs/07-auth.md](docs/07-auth.md) | Passwordless email one-time-code login for apps (forward_auth) |
| [docs/08-security-model.md](docs/08-security-model.md) | Security model: which benchmark governs each layer + the exceptions register |
| [docs/09-recovery.md](docs/09-recovery.md) | Rebuilding a lost box, the rebuild drill and RTO log, the panic guard and crash record |
| [docs/10-lts-migration.md](docs/10-lts-migration.md) | Moving instances to the next Ubuntu release |
| [docs/11-incident-response.md](docs/11-incident-response.md) | Containment, evidence, notification duties and rebuild after a suspected compromise |
| [docs/12-applying-scaffold-updates.md](docs/12-applying-scaffold-updates.md) | How scaffold changes reach an existing box (the two lanes, the site play) |
| [docs/13-secrets.md](docs/13-secrets.md) | SOPS-encrypted secrets in git, rendered at deploy |
| [docs/14-server-tooling.md](docs/14-server-tooling.md) | The shared server tooling and CI workflows, carried by the pointer |
| [docs/15-release-tree.md](docs/15-release-tree.md) | The release tree: root fetches, verifies and exports each deploy |

## CI

GitHub Actions runs four jobs on pushes to `main` and on pull requests:
- lint (shellcheck, python, the renderer and secrets checks, playbook syntax)
- Molecule `default`
- Molecule `backup`
- `backup/tests/integration/run_tests.sh`

A separate `Compliance Audits` workflow runs on GitHub-hosted Ubuntu 24.04,
applies `bootstrap.yml` plus `site-first-run.yml`, then publishes OpenSCAP and
Docker audit reports as workflow artifacts. On `main`, it also publishes a
static report index to GitHub Pages.

Workflow files:
- `.github/workflows/ci.yml`
- `.github/workflows/compliance-audits.yml`

## Repository structure

```
vps-base-template/
├── ansible/
│   ├── roles/
│   │   ├── common/          # base packages, auto-updates, fail2ban, swap (zram + encrypted file), monitoring, earlyoom
│   │   ├── deploy-user/     # deploy + admin accounts, sudoers, root-owned wrappers, server age key
│   │   ├── ssh-hardening/   # wraps dev-sec.io ssh_hardening
│   │   ├── os-hardening/    # wraps dev-sec.io os_hardening
│   │   ├── baseline-hardening/  # auditd, AIDE, AppArmor, sysctls, CIS closures
│   │   ├── docker/          # Docker CE + compose plugin, memory tier slices, weekly prune timer
│   │   ├── firewall/        # ufw + Docker-aware published-port filtering
│   │   ├── backup/          # hourly PostgreSQL → Restic backups + weekly verification + restore drill
│   │   ├── vuln-scan/       # daily Trivy scan of running images
│   │   ├── log-export/      # hourly off-host log export (Object-Locked bucket)
│   │   └── notify/          # ntfy, dead-man's switch, panic guard, crash record, digest
│   ├── bootstrap.yml
│   ├── site-first-run.yml
│   ├── site-quick.yml
│   ├── audit-all.yml
│   ├── audit-lynis.yml
│   ├── audit-openscap.yml
│   ├── audit-docker.yml
│   ├── audit-compose.yml
│   ├── audit-vuln.yml
│   ├── group_vars/all.yml
│   └── requirements.yml
├── backup/
│   ├── backup.sh            # wrapper → ansible/roles/backup/files/backup.sh
│   ├── restore.sh           # wrapper → ansible/roles/backup/files/restore.sh
│   └── tests/integration/   # end-to-end backup + restore tests (Docker + restic)
├── docker/
│   ├── caddy.base.yml
│   ├── Caddyfile.example
│   └── Caddyfile.local.example
├── molecule/
│   ├── default/             # Ubuntu 24.04 — all roles, restricted mode
│   └── backup/              # Ubuntu 24.04 — backup role deployment
├── scripts/                 # repo tooling; scripts/server/ is the servers' shared tooling (docs/14)
├── server-files/            # canonical copies of what every server repo carries
└── docs/
```
