# Server Repo Structure

Each VPS has its own git repo. The `server-template/` directory in this
scaffold is the reference schema — copy it to start a new server repo.

## Creating a server repo

```bash
cp -r path/to/vps-scaffold/server-template/ server-myserver
cd server-myserver
git init
git submodule add git@github.com:yourorg/vps-scaffold.git scaffold
git add .
git commit -m "chore: initialise server repo"
```

Then fill in:

```bash
cp .env.example .env                   # set DOMAIN, ACME_EMAIL
cp ansible/hosts.example ansible/hosts # set server IP
```

## Structure

```
server-myserver/
├── scaffold/                    ← vps-scaffold submodule
├── apps/
│   └── myapp/
│       ├── docker-compose.yml   ← pulls image from Docker Hub
│       ├── .env.example         ← committed: lists required vars (no values)
│       └── myapp.caddy          ← Caddy routing snippet
├── Caddyfile                    ← import /srv/repo/apps/*/*.caddy
├── Caddyfile.local              ← local dev (self-signed certs)
├── docker-compose.yml           ← includes scaffold base + each app
├── docker-compose.override.yml.example
├── .env.example                 ← committed: DOMAIN, ACME_EMAIL
├── .gitignore
└── ansible/
    └── hosts.example
```

## Adding an app

Each app gets a folder in `apps/`. There are no conventions beyond the three
files — compose, env, and caddy snippet. Services, volumes, and environment
variables are specific to each app and written by hand.

**`apps/myapp/docker-compose.yml`** — pull image, join caddy network:
```yaml
services:
  myapp:
    image: yourorg/myapp:latest
    restart: unless-stopped
    env_file: apps/myapp/.env
    networks:
      - caddy

networks:
  caddy:
    external: true
    name: caddy
```

**`apps/myapp/.env.example`** — commit this, listing every variable:
```bash
DATABASE_URL=
SECRET_KEY=
```

**`apps/myapp/myapp.caddy`** — routing snippet, uses `{$DOMAIN}` from server `.env`:
```
myapp.{$DOMAIN} {
    reverse_proxy myapp:3000
}
```

Then add one line to the root `docker-compose.yml`:
```yaml
include:
  - scaffold/docker/caddy.base.yml
  - apps/myapp/docker-compose.yml   ← add this
```

Caddy picks up `myapp.caddy` automatically via the glob — no changes to
`Caddyfile` needed.

## Gitignore conventions

```gitignore
.env              # server secrets
apps/**/.env      # app secrets — .env.example IS committed
ansible/hosts     # contains server IP
docker-compose.override.yml
```

## Where Secrets Live

There are two secret workflows in the current template:

- Runtime secrets are server-local:
  - `.env`
  - `apps/*/.env`
  Edit these in `/opt/deploy` on the VPS, because Docker Compose reads them
  directly from the deployed checkout.

- Backup secrets are Ansible-managed:
  - `backup/config.env`
  - `backup/services/*.env`
  Edit these locally in your server repo on your laptop, then run the backup
  playbook so Ansible copies them to `/etc/restic/` on the server.

## Provisioning

See [03-provisioning-a-server.md](03-provisioning-a-server.md) for the full
walkthrough. The short version from the server repo root:

```bash
ansible-galaxy collection install -r scaffold/ansible/requirements.yml
ansible-playbook -i ansible/hosts scaffold/ansible/bootstrap.yml
ansible-playbook -i ansible/hosts scaffold/ansible/site-first-run.yml
ansible-playbook -i ansible/hosts scaffold/ansible/site-quick.yml
```

## Local development

```bash
cp docker-compose.override.yml.example docker-compose.override.yml
docker compose up -d
docker compose exec caddy caddy trust   # once per machine
```
