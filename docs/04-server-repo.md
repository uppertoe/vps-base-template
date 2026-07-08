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
├── Caddyfile                    ← base Caddy config
├── .generated/caddy/            ← rendered bundle (committed, CI-checked)
│   ├── apps.caddy               ← all app routes, mounted into Caddy
│   └── networks.yml             ← per-app proxy-network wiring
├── Caddyfile.local              ← local dev (self-signed certs)
├── docker-compose.yml           ← includes scaffold base + each app
├── docker-compose.override.yml.example
├── .env.example                 ← committed: DOMAIN, ACME_EMAIL
├── .gitignore
└── ansible/
    └── hosts.example
```

## Adding an app

Each app gets a folder in `apps/`. There are two conventions: the three files —
compose, env, and caddy snippet — and the web-facing service being named after
the app folder (`apps/myapp/` → service `myapp`). Services, volumes, and
environment variables are otherwise specific to each app and written by hand.

Networking is generated, not hand-written: the scaffold gives every app its own
private proxy network (`myapp_proxy`), attaches Caddy to all of them, and each
app only to its own. Apps can never reach each other's backends or forge the
`Remote-*` auth headers. Don't add proxy networks to app compose files; private
backend networks (app ↔ its own db) are yours to define as usual.

**`apps/myapp/docker-compose.yml`** — pull image and apply the CIS Docker §5
runtime hardening block (see below):
```yaml
services:
  myapp:
    image: yourorg/myapp:1.2.3@sha256:…   # pin a digest, never :latest
    restart: unless-stopped
    env_file: apps/myapp/.env
    # --- CIS Docker §5 runtime hardening ---
    user: "1000:1000"            # run non-root (match your image's user)
    cap_drop: [ALL]              # drop all caps, add back only what you need
    security_opt:
      - no-new-privileges:true
    read_only: true              # immutable root fs; writable paths via tmpfs/volumes
    tmpfs: [/tmp]
    mem_limit: 256m              # bound memory (2 GB host)
    pids_limit: 256              # fork-bomb guard
    healthcheck:
      test: ["CMD", "…"]
      interval: 15s
      timeout: 5s
      retries: 3
    # ----------------------------------------
```

### Container hardening (CIS Docker §5)

Every app container should carry the block above. These controls are verified on
the running stack by `scaffold/ansible/audit-compose.yml` and linted in CI, so a
container that skips them shows up as a finding. The rules:

| Control | Why |
|---------|-----|
| `image: …@sha256:` digest, never `:latest` | reproducible, tamper-evident pulls (weekly digest-freshness check flags drift; enable the Renovate app for automated bump PRs) |
| `user:` non-root | a container escape lands as an unprivileged user |
| `cap_drop: [ALL]` (+ minimal `cap_add`) | remove kernel capabilities the app never uses |
| `security_opt: [no-new-privileges:true]` | block setuid privilege escalation (also a daemon default) |
| `read_only: true` + `tmpfs`/named volumes | tamper-resistant root filesystem |
| `mem_limit` + `pids_limit` | contain a single app from exhausting the 2 GB host |
| `healthcheck` | the deploy waits for health; surfaces crash-loops |
| never set `privileged: true`, never mount `/var/run/docker.sock` | both hand the host to the container |

The base `caddy` service and the bundled `auth` app already follow this pattern —
copy from them. Caddy is the one documented exception that keeps a single
capability (`NET_BIND_SERVICE`) so it can bind ports 80/443 as non-root.

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
  - .generated/caddy/networks.yml
  - apps/myapp/docker-compose.yml   ← add this
```

and re-render the committed bundle:
```bash
bash scaffold/docker/render-caddy-routes.sh
git add .generated
```

The renderer regenerates `.generated/caddy/apps.caddy` (every app's routes —
Caddy mounts this file instead of the deploy repo, keeping `.env` and backup
secrets off the reverse proxy) and `.generated/caddy/networks.yml` (the per-app
proxy networks). Both are committed like lockfiles; CI fails if they drift from
the sources, and `audit-compose.yml` fails at runtime if two apps ever share a
proxy network.

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

The deploy helper enforces this split on every run: the `.env` set above is
locked to mode 600, and everything else containers consume from the checkout
(`apps/`, `scaffold/`, `.generated/`, `Caddyfile`) is normalised to
world-readable. The second half matters because containers run as dedicated
non-root uids: a file created under the host's hardened umask is otherwise
unreadable inside any container whose uid differs from the deploy user's, and
which files those are depends on who created them, not on what is in git. Put
secrets ONLY in the `.env` set — any other file in the checkout must be
assumed readable by every container that mounts it.

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
