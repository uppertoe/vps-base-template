# vps-base-template

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
| `ansible/roles/common` | Base packages, auto-updates, fail2ban, swapfile, monitoring, earlyoom |
| `ansible/roles/deploy-user` | Non-root deploy user, SSH key, sudoers |
| `ansible/roles/ssh-hardening` | Hardens sshd (wraps dev-sec.io) |
| `ansible/roles/os-hardening` | Kernel-level hardening (wraps dev-sec.io) |
| `ansible/roles/docker` | Docker CE + compose plugin + weekly prune timer |
| `ansible/roles/firewall` | UFW + Docker-aware filtering for published ports |
| `ansible/roles/backup` | Hourly PostgreSQL → Restic backups + off-hour weekly verification |
| `ansible/bootstrap.yml` | Run once as root — creates deploy user |
| `ansible/site.yml` | Default quick-apply path — hardening, Docker, firewall |
| `ansible/site-first-run.yml` | Heavier first-run/compliance pass — includes safe upgrade + AIDE init |
| `ansible/site-quick.yml` | Explicit fast day-to-day apply path |
| `ansible/audit-*.yml` | Lynis, OpenSCAP, docker-bench security audits |
| `docker/caddy.base.yml` | Base Caddy service — included by server repos |
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
| [docs/06-auditing.md](docs/06-auditing.md) | Lynis + OpenSCAP + docker-bench auditing |

## CI

GitHub Actions runs three checks on pushes to `main` and on pull requests:
- Molecule `default`
- Molecule `backup`
- `backup/tests/integration/run_tests.sh`

Workflow file: `.github/workflows/ci.yml`

## Repository structure

```
vps-base-template/
├── ansible/
│   ├── roles/
│   │   ├── common/          # base packages, auto-updates, fail2ban, swap, monitoring, earlyoom
│   │   ├── deploy-user/     # non-root user + SSH key + sudoers
│   │   ├── ssh-hardening/   # wraps dev-sec.io ssh_hardening
│   │   ├── os-hardening/    # wraps dev-sec.io os_hardening
│   │   ├── docker/          # Docker CE + compose plugin + weekly prune timer
│   │   ├── firewall/        # ufw + Docker-aware published-port filtering
│   │   └── backup/          # hourly PostgreSQL → Restic backups + off-hour weekly verification
│   ├── bootstrap.yml
│   ├── site.yml
│   ├── site-first-run.yml
│   ├── site-quick.yml
│   ├── audit-lynis.yml
│   ├── audit-openscap.yml
│   ├── audit-docker.yml
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
│   ├── default/             # Ubuntu 24.04 — all roles
│   └── backup/              # Ubuntu 24.04 — backup role deployment
└── docs/
```
