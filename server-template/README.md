# server-[name]

VPS implementation repo for `[name]`. Based on [vps-scaffold](https://github.com/yourorg/vps-scaffold).

## Structure

```
.
├── scaffold/          ← vps-scaffold submodule (Ansible roles, Caddy base)
├── apps/
│   └── [app-name]/
│       ├── docker-compose.yml   ← image from Docker Hub, joins caddy network
│       ├── .env.example         ← committed: documents required env vars
│       └── [app-name].caddy     ← Caddy routing for this app
├── Caddyfile          ← auto-discovers apps/*/*.caddy — rarely needs editing
├── Caddyfile.local    ← local dev override (self-signed certs)
├── docker-compose.yml ← includes scaffold base + each app
├── .env.example       ← committed: DOMAIN, ACME_EMAIL, any shared vars
└── ansible/
    └── hosts.example  ← copy to hosts (gitignored), set server IP
```

## Adding an app

1. Create `apps/[name]/` with three files:

**`docker-compose.yml`**
```yaml
services:
  [name]:
    image: yourorg/[name]:latest
    restart: unless-stopped
    env_file: apps/[name]/.env
    networks:
      - caddy

networks:
  caddy:
    external: true
    name: caddy
```

**`.env.example`** — list every variable the app needs (no values)

**`[name].caddy`**
```
[name].{$DOMAIN} {
    reverse_proxy [name]:3000
}
```

2. Add one line to `docker-compose.yml`:
```yaml
include:
  - apps/[name]/docker-compose.yml
```

That's it. Caddy picks up `[name].caddy` automatically on next reload.

## Provisioning

```bash
# Install Ansible dependencies (once)
ansible-galaxy collection install -r scaffold/ansible/requirements.yml

# Bootstrap: creates deploy user (once per server, runs as root)
ansible-playbook -i ansible/hosts scaffold/ansible/bootstrap.yml

# Full setup: hardening, Docker, firewall (idempotent — safe to re-run)
ansible-playbook -i ansible/hosts scaffold/ansible/site.yml
```

## Deploying

```bash
ssh [server]
cd /opt/deploy
git clone --recurse-submodules [repo-url] .
cp .env.example .env         # fill in real values
cp apps/[name]/.env.example apps/[name]/.env   # per app
docker compose up -d
```

## Local development

```bash
cp docker-compose.override.yml.example docker-compose.override.yml
docker compose up -d
docker compose exec caddy caddy trust   # once per machine
```

## Auditing

```bash
ansible-playbook -i ansible/hosts scaffold/ansible/audit-lynis.yml
ansible-playbook -i ansible/hosts scaffold/ansible/audit-openscap.yml
ansible-playbook -i ansible/hosts scaffold/ansible/audit-docker.yml
```
