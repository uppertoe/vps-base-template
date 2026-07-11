# Admin dashboard (optional)

A tiny static admin hub at `admin.<DOMAIN>`: a card grid linking to the
estate's management surfaces, served by `busybox httpd` behind the gateway
admin guard (`import protected_admin`). It carries no secrets, no database, and
trusts no injected headers — it just serves static HTML — so it needs none of
the shared-secret handshaking that header-trusting apps (e.g. the user portal)
require.

The shell (`www/index.html`) is **scaffold-owned and domain-agnostic**: it lists
the platform-standard admin surfaces (the User portal at `users.<DOMAIN>` and
SSO at `sso.<DOMAIN>`) and derives `<DOMAIN>` from the browser at load, so it
works unmodified on any deployment. Improvements ship to every server on the
next scaffold submodule bump.

This is **opt-in**. Enable it per server by adding the app to the server repo.

## Enable on a server repo

1. Create `apps/dashboard/dashboard.caddy`:

   ```caddy
   admin.{$DOMAIN} {
   	import protected_admin dashboard:8080
   }
   ```

2. Create `apps/dashboard/docker-compose.yml` — a self-contained CIS Docker §5
   service named `dashboard` (the web-facing service must be named after the
   directory) that mounts the scaffold shell read-only:

   ```yaml
   services:
     dashboard:
       image: busybox:latest@sha256:<pin>   # reuse the pin already in the repo
       command: ["httpd", "-f", "-v", "-p", "8080", "-h", "/www"]
       working_dir: /www
       volumes:
         # Scaffold-owned shell: auto-updates on submodule bump. To use your own
         # link set instead, create apps/dashboard/www/index.html and change this
         # to  - ./www:/www:ro
         - ../../scaffold/docker/dashboard/www:/www:ro
       restart: unless-stopped
       user: "1000:1000"
       cap_drop: [ALL]
       security_opt:
         - no-new-privileges:true
       read_only: true
       mem_limit: 32m
       pids_limit: 32
       healthcheck:
         test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/"]
         interval: 30s
         timeout: 5s
         retries: 3
         start_period: 5s
   ```

   The §5 block is inlined (not `extends`-ed from the scaffold) on purpose: the
   compose security lint (KICS) scans each `apps/*` file statically and does not
   follow `extends` across the submodule boundary, so the guarantees must be
   visible in the file it scans. This matches every other app in the repo.

3. Uncomment/add the include line in the root `docker-compose.yml`:

   ```yaml
   - apps/dashboard/docker-compose.yml
   ```

4. Re-render the Caddy bundle and commit:

   ```sh
   bash scaffold/docker/render-caddy-routes.sh && git add .generated apps/dashboard
   ```

Requires `apps/authelia` (for the admin guard + SSO link) and, for the portal
link, `apps/users`.

## Customise the links

The default shell covers the platform-standard surfaces. To add
deployment-specific links (extra apps, an ops tool):

1. Copy `scaffold/docker/dashboard/www/index.html` to `apps/dashboard/www/index.html`.
2. Edit the `LINKS` array in the `<script id="cfg">` block near the top — one
   object per card. That's the only edit needed; the href and host label are
   built at load from the browser's domain.

   ```js
   var LINKS = [
     { sub: "users",  name: "User portal", icon: "users",
       desc: "Invite, edit access, offboard SSO users" },
     { sub: "auth", path: "/admin/", name: "Single sign-on", icon: "lock",
       desc: "Login wall admin — groups, invite codes & 2FA" },
     // add your own:
     { sub: "grafana", name: "Grafana", icon: "chart", group: "Observability",
       desc: "Metrics & dashboards" },
   ];
   ```

   Fields: `sub` (required, subdomain → `https://<sub>.<DOMAIN>`), `path`
   (optional, appended — e.g. `/admin/`), `name`, `desc`, `icon` (one of
   `users, lock, board, bell, book, chart, server, key, beaker, mic, layout,
   link`), and `group` (optional section heading; defaults to `Administration`).

3. Point the compose mount at your copy: `- ./www:/www:ro`.

A customised deployment opts out of shell auto-updates (it owns the file); the
default (scaffold-mounted) deployment keeps getting them.
