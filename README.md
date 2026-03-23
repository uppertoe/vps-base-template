# vps-scaffold

Infrastructure base for hardened VPS instances running Dockerised apps behind
Caddy. Used as a git submodule in per-server repos.

## Two repos, one server

```
vps-scaffold/          ← this repo — infrastructure, don't edit per-server
server-[name]/         ← your repo — apps, config, Caddyfile, .env
  └── scaffold/        ← submodule pointing here
```

`vps-scaffold` provides the Ansible roles, Caddy base compose, and Molecule
test suite. Your server repo provides everything specific to that VPS.

## What this repo provides

| Path | Purpose |
|------|---------|
| `ansible/roles/` | deploy-user, ssh-hardening, os-hardening, docker, firewall |
| `ansible/bootstrap.yml` | Run once as root — creates deploy user |
| `ansible/site.yml` | Idempotent — hardening, Docker, firewall |
| `ansible/audit-*.yml` | Lynis, OpenSCAP, docker-bench security audits |
| `docker/caddy.base.yml` | Base Caddy service — included by server repos |
| `server-template/` | Reference schema for server repos |
| `molecule/` | Ubuntu 24.04 + Debian 12 test scenario |

## Creating a server repo

Copy `server-template/` as the starting point for a new server repo:

```bash
cp -r server-template/ ../server-myserver
cd ../server-myserver
git init
git submodule add git@github.com:yourorg/vps-scaffold.git scaffold
```

See `server-template/README.md` for the full structure and conventions.

## Documentation

| Doc | What it covers |
|-----|----------------|
| [docs/01-prerequisites.md](docs/01-prerequisites.md) | SSH keys, Ansible, Python venv setup |
| [docs/02-local-testing.md](docs/02-local-testing.md) | Running the Molecule test suite |
| [docs/03-provisioning-a-server.md](docs/03-provisioning-a-server.md) | Full provisioning walkthrough |
| [docs/04-server-repo.md](docs/04-server-repo.md) | Server repo structure and conventions |
| [docs/06-auditing.md](docs/06-auditing.md) | Lynis + OpenSCAP + docker-bench auditing |

## Repository structure

```
vps-scaffold/
├── ansible/
│   ├── roles/
│   │   ├── common/          # base packages, auto-updates, fail2ban
│   │   ├── deploy-user/     # non-root user + SSH key + sudoers
│   │   ├── ssh-hardening/   # wraps dev-sec.io ssh_hardening
│   │   ├── os-hardening/    # wraps dev-sec.io os_hardening
│   │   ├── docker/          # Docker CE + compose plugin + weekly prune timer
│   │   └── firewall/        # ufw — allow 22, 80, 443 only
│   ├── bootstrap.yml
│   ├── site.yml
│   ├── audit-lynis.yml
│   ├── audit-openscap.yml
│   ├── audit-docker.yml
│   ├── group_vars/all.yml
│   └── requirements.yml
├── docker/
│   ├── caddy.base.yml
│   ├── Caddyfile.example
│   └── Caddyfile.local.example
├── server-template/         ← reference schema for server repos
├── molecule/
│   └── default/             # Ubuntu 24.04 + Debian 12
└── docs/
```
