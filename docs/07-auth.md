# Authentication (email one-time-code)

The scaffold can put a passwordless login wall in front of any app using
[vps-scaffold-auth](https://github.com/uppertoe/vps-scaffold-auth), a small Go
gateway that Caddy asks before each guarded request. Users enter their email,
receive a 6-digit code, type it in, and get a session. No passwords, no passkeys, no third-party identity
provider.

It runs as a normal app under `apps/auth/`, consumed as a prebuilt image from
`ghcr.io/uppertoe/vps-scaffold-auth`. The image is public, so the VPS pulls it
with no credentials.

## How it works

```
browser ─▶ Caddy (app.example.com)
              │  import role "app" "user" ─▶ GET auth:8080/verify, naming the app and role
              │                        ├─ holds the role → 200 + Remote-User/Email/Roles → app
              │                        ├─ signed in, no role → the gateway's "no access" page
              │                        └─ no session    → 302 → auth.example.com/login
              ▼
           auth.example.com  ── email → 6-digit code → HMAC-signed session cookie (.example.com)
```

- Caddy calls `GET /verify` on every request to a guarded path, naming the
  app and the role the path needs.
- When the person holds that role, the gateway returns `200` with
  `Remote-User`, `Remote-Email` and `Remote-Roles`, which Caddy forwards to
  the app. `Remote-Roles` lists the roles the person holds in that app.
- A request without a session is sent to the login page, and a signed-in
  person who holds no role in the app is shown the gateway's "no access" page.
- The session is a stateless, HMAC-signed cookie scoped to the parent domain, so
  one login covers every app subdomain.

Each app declares its roles in its Caddy snippet, and the gateway's admin
pages decide who holds each one. The guard snippets are in the server repo's
`apps/auth/auth.caddy`, a copy of the gateway's `deploy/auth.caddy`, and the
route renderer lists what each site requires in
`.generated/caddy/route-access.tsv`. The service keeps its state in a small
SQLite file, with no Postgres or Redis.

## Enabling it

The server repo (from `server-instance-template`) ships the wiring under
`apps/auth/`. It is **opt-in** so an unconfigured server never crash-loops on
deploy.

1. Configure the gateway's settings (`SESSION_SECRET` from
   `openssl rand -hex 32`, `ALLOWED_EMAIL_DOMAINS`, `ADMIN_EMAILS`, the
   `EMAIL_*` values; `apps/auth/.env.example` lists them all). Where they are
   written depends on the server ([13-secrets.md](13-secrets.md)):
   - On a SOPS server, edit `secrets/apps/auth/.env.sops` with `sops` on your
     laptop, then commit signed and push. The deploy renders it to
     `apps/auth/.env` on the box, and an edit made on the box is overwritten
     by the next deploy.
   - On a server without SOPS, copy `apps/auth/.env.example` to
     `apps/auth/.env` on the server and edit it there.
2. Uncomment the auth include in the root `docker-compose.yml`:
   ```yaml
   include:
     - scaffold/docker/caddy.base.yml
     - .generated/caddy/networks.yml
     - apps/auth/docker-compose.yml   # ← uncomment this
   ```
3. Point a DNS record for `auth.<your-domain>` at the server (so Caddy can issue
   its certificate), then deploy (`~/deploy` on the server, or
   `docker compose up -d` locally).

`apps/auth/.env` is gitignored and reset to mode 600 by the deploy helper.

## Protecting an app

An app declares the roles it has and leaves the gateway's admin pages to
decide who holds each one. Guard each `handle` with `import role`, naming the
app, the role its paths need and the app's upstream, and declare every role
other than `user` above the site address:

```caddyfile
# apps/fellows/fellows.caddy
# scaffold-app-label: "Fellowship enquiries"
# scaffold-roles: admin "Administrator"
# scaffold-card-pages: /enquiry "Your enquiry"
enquiries.{$DOMAIN} {
	import error_pages /srv/www/dash
	@public path / /faq /privacy /static/* /healthz
	handle @public {
		# scaffold-lint: open-path -- / /faq /privacy: read before a person signs in
		reverse_proxy fellows:8080 {
			import strip_public
		}
	}
	handle /admin/* {
		import role "enquiries" "admin" fellows:8080
	}
	handle {
		import role "enquiries" "user" fellows:8080
	}
}
```

Caddy sends each request to one `handle`, so here `/admin/*` needs the admin
role, the public pages need none, and every other path needs the user role. Markers describe the app. They sit on comment
lines just above the site address or inside the site block.

- `# scaffold-roles: <role> "<Label>" ...` declares the app's roles beyond
  `user`, which every app has with the label "User". A role name uses
  lower-case letters, digits, `-` and `_`.
- `# scaffold-app-label: "<Label>"` sets the name the gateway's admin pages
  show. Without it, the gateway shows the app name with its first letter in
  capitals and `-` or `_` read as a space.
- `# scaffold-card-pages: <path> "<Label>" ...` lists the pages a break-glass
  card for the app may open. Each must be an exact path that a `user` guard
  decides, because a card holds only the user role.
- `# scaffold-app: <app>` names the app. The marker is optional, and when
  present it must name the app that the site's guards name.

An open path is declared with the same `open-path` marker that any gated site
uses (docs/04), and the gateway shows the text after its colon as the reason.
Access from a named network is assigned on the gateway's admin pages, so a
handle with a network matcher has no place in a site guarded by roles.

> **Requires the auth service enabled.** The guards and the `auth.{$DOMAIN}`
> login site route to the `auth` container. The snippets are always defined,
> so Caddy starts, but guarded routes return `502` until you
> [enable auth](#enabling-it).

> **Trust model.** Apps trust the `Remote-*` headers because only Caddy shares
> each app's proxy network: apps publish no host ports. Every guard deletes
> any client-supplied `Remote-User`, `Remote-Email`, `Remote-Roles`,
> `X-Auth-App` and `X-Auth-Role` before it asks the gateway, and copies the
> gateway's values only when the gateway admits the request, so a client cannot send a forged
> `Remote-Roles: admin` past the guard. Never expose a guarded app directly,
> never put unrelated apps on the same proxy network, and have apps read
> identity from these headers alone.

The renderer writes `.generated/caddy/app-roles.tsv`, which the gateway reads
as `APP_ROLES_FILE`. For the example above the file holds these lines, with
one tab between fields:

```tsv
enquiries	user	User	enquiries.{$DOMAIN}
enquiries	admin	Administrator	enquiries.{$DOMAIN}
@label	enquiries	Fellowship enquiries
@source	enquiries	apps/fellows/fellows.caddy
@open	enquiries	/ /faq /privacy /static/* /healthz	read before a person signs in
@path	enquiries	/admin/*	admin
@path	enquiries	*	user
@card-page	enquiries	/enquiry	Your enquiry
```

The paths on each line come from the handle's matcher: an inline path, a
one-line `@name path ...` matcher, or no matcher at all, which stands for
every path the other handles do not name (`*`). A `path_regexp` matcher is
refused, on an open handle as on a guarded one, because Caddy may answer
more paths than the manifest could list. The gateway decides a path by an
exact path first, then the longest prefix, then `*`. Caddy compares handles
by path length only when each has a single path, and otherwise keeps the
written order, so the renderer refuses two handles whose paths overlap
unless both need the same role or both are open. The two rules then always
reach the same decision.

### Adding to the request toward the app

`import role` writes its own `reverse_proxy`, so an app that needs something
added to the request toward it, such as a shared secret in a header, writes
the route out and imports the gate inside it. The renderer counts
`import auth_gate_role "<app>" "<role>"` as it counts `import role`, in the
manifest and in every refusal below.

```caddyfile
	handle /admin/* {
		route {
			import strip_client_identity
			request_header -X-Auth-App
			request_header -X-Auth-Role
			import auth_gate_role "enquiries" "admin"
			reverse_proxy fellows:8080 {
				import strip_auth_cookie
				header_up X-Proxy-Secret {$FELLOWS_PROXY_SECRET}
			}
		}
	}
```

The renderer does not read inside a snippet that the app defines, so the
route must be written out in each guarded handle.

### A site that serves files or redirects

Two further guards cover a site with no upstream. `import role_gate "<app>"
"<role>"` admits a person who holds the role and lets the site's own handler,
such as a `file_server`, answer the request. `import role_redir "<app>"
"<role>" "<target>"` admits the same person and then redirects to the target.

```caddyfile
	handle /old/* {
		import role_redir "handbook" "user" "https://handbook.{$DOMAIN}/"
	}
	handle {
		import role_gate "handbook" "user"
		root * /srv/handbook
		file_server
	}
```

The gateway's `deploy/auth.caddy` defines both snippets, and each server repo
copies them with the other guards. The renderer counts both as it counts
`import role`, in the manifest, in the route lint, in `route-access.tsv` and
in every refusal below.

A public page that greets a signed-in visitor by name may ask `/verify` only
when a session cookie is present, sending `header_up X-Auth-App "<app>"` and
`header_up X-Auth-Role "<role>"`, and serve the page whatever the answer.
Such a handle is an open path: it needs the `open-path` marker and a reason,
and it is not a guard. The render fails if
`X-Auth-App` names an app other than the site's, if `X-Auth-Role` names a
role the app does not declare, or if the site has no role guard.

The render fails, naming the file and line, in each of these cases:

- a guard names a role that the snippet does not declare;
- an app has role guards but none for `user`;
- two site blocks use the same app name, in one snippet or in two, or one
  site guards with two apps;
- a snippet imports an older guard: `protected` or any `protected_*` form,
  `auth_gate` or one of its variants, or a `*_gate` or `*_redir` snippet
  other than `role_gate` and `role_redir`. The gateway no longer accepts
  them, and the error names the snippet;
- a site mixes a role guard with `forward_auth`, which names no app;
- a `route` block sits at the top level of the site, where Caddy runs it
  after every `handle` whatever its path (write it as a `handle`; a `route`
  inside a `handle` is fine, and `import role` at the top level decides `*`);
- an open-path marker sits at the top level of the site, or on a catch-all
  `handle` and names paths other than the whole site (`/*` or `*`), where it
  would open every path that no other handle names;
- in a site whose catch-all is open, a guarded exact path such as
  `/guidelines` lacks `/guidelines/*` (or `/guidelines*`) guarded by the same
  role, so the catch-all would answer `/guidelines/` and the paths below it;
- a `handle`, `handle_path` or `invoke` sits inside a guarded handle, where
  Caddy would run it before the gate (put those paths in a top-level handle
  with a guard of their own; a `route` inside a guarded handle is fine);
- a card page is decided by an open path or by a role other than `user`;
- a handle's matcher is not a path matcher (`path_regexp` included), a path
  cannot be written as an exact path or a prefix ending in `*`, or two
  handles declare the same path;
- a path in one handle falls under a prefix in another (ignoring case, as
  Caddy does) and the two handles decide differently, for example
  `handle /users/*` for `user` beside `@adm path /a /users/admin` for
  `admin`;
- an app-roles marker, `# scaffold-app:` included, sits on a site that has
  no role guard;
- a `# scaffold-app:` marker names an app other than the one the site's role
  guards name.

The auth service reads the manifest once its compose file mounts it, which
the server repos add in this form:

```yaml
    environment:
      - APP_ROLES_FILE=/etc/vps-auth/app-roles.tsv
    volumes:
      - ../../.generated/caddy/app-roles.tsv:/etc/vps-auth/app-roles.tsv:ro
```

The list of groups each app may read from the members endpoint,
`.generated/caddy/member-readers.tsv`, is mounted beside it in the same way
as `MEMBER_READERS_FILE`; docs/04 "An app that reads group members" gives
the lines.

### A public site with protected sections

A site that is public apart from a few sections guards those sections in a
handle of their own and leaves the catch-all `handle` open. The marker on the
catch-all must name the whole site, as `/*` or `*`:

```caddyfile
{$DOMAIN} {
	@gated path /guidelines /guidelines/* /cardiac /cardiac/*
	handle @gated {
		import role_gate "home" "user"
		file_server
	}
	handle {
		# scaffold-lint: open-path -- /*: the homepage and service directory are public
		file_server
	}
}
```

The manifest then holds `@open	home	*	<reason>`, and the guarded handle still
decides its own paths. Each guarded section needs its exact path and its
prefix, as `/guidelines /guidelines/*`, because the open catch-all would
otherwise answer `/guidelines/` and every path below it; the renderer refuses
an exact path without its prefix. The renderer also refuses a catch-all
marker that lists anything narrower than the whole site, and an open-path
marker at the top level of the site, so the open directives belong in the
catch-all `handle`. A card page must sit under a guarded section, not on a
page the catch-all decides.

This shape is meant for a site that Caddy's `file_server` answers, or for an
upstream that reads a path exactly as Caddy matches it. Caddy decides which
handle answers from the path as it arrives, so an upstream that drops a
`;parameter` from a path segment, or reads `\` as `/`, can be asked for a
guarded page by a path that Caddy sends to the open catch-all. Such an app
should keep a guarded catch-all and open only the paths it names.

### Checking the routes

`docker/check-routes.sh` requests every path the manifest declares, without
signing in, and fails if a guarded path is served or an open path is sent to
the sign-in page. Beside each open path it also requests one path that the
open path does not cover, such as `/faq/scaffold-route-check-beside` for
`/faq` or `/static` for `/static/*`, and fails if that path is served without
sign-in. For an open `*` it requests a made-up path,
`/scaffold-route-check-elsewhere`, which must be served without sign-in.
Below each exact guarded path it requests one more, such as
`/guidelines/scaffold-route-check` for `/guidelines`, which must be sent to
sign in. On
the server, from `/opt/deploy`, run:

```bash
bash scaffold/docker/check-routes.sh --connect 127.0.0.1 example.org
```

`--connect` sends the requests to the local Caddy while keeping each host
name, and `--insecure` skips the certificate check for a local Caddy with its
own certificate authority. Only a redirect to `/login` on the gateway's
own host counts as being sent to sign in, so an app that sends a visitor to
its own `/login` page fails the check. The gateway's host is taken to be
`auth.<DOMAIN>`; if the server runs it under another name, pass that name
with `--auth-host`, for example `--auth-host auth.example.net`. Run the check from outside any network that the
gateway admits by itself, because a network assignment can grant a role
without sign-in. The check does not yet sign in with each role, since that
needs a test session the script cannot create.

## Admin two-factor (default on)

Email codes inherit the security of the user's inbox. For the higher-trust admin
tier TOTP is required by default (`TOTP_ENABLED=true` in the template
`apps/auth/.env.example`). Enrolment is **admin-provisioned, never self-service
at login** — otherwise an attacker who only controls the inbox could bootstrap
the second factor. An un-enrolled admin is refused at login and told to ask an
administrator. Bootstrap the first admin from the box (prints the `otpauth://`
URL and setup key once — treat as a secret). On a restricted-mode server the
deploy account cannot run `docker compose`, so connect as the admin account:

```bash
cd /opt/deploy && docker compose exec -T auth /app -totp-enroll admin@example.org
```

Subsequent admins are minted from the `/admin/totp` page by an already
signed-in admin (or the same CLI); `-totp-remove` is the lost-device
break-glass. Enrolled admins are challenged for a code at every login.
Regular users stay code-only.

The resulting factor posture — cite it this way in a security review (and in
the SSP template, `docs/templates/system-security-plan.md`):

- **Host administration:** key-only SSH (possession factor; passphrase-protect
  the key so it is possession + knowledge), root login disabled.
- **Application admin:** email OTP **+ TOTP** — two factors on privileged app
  access (the ISM-1173 / Essential Eight expectation).
- **Regular users:** email OTP, single factor by design — document the
  rationale (clinical usability, no accounts/passwords to phish or reuse) and
  the upgrade path (per-user TOTP or WebAuthn are natural extensions of the
  same service).

Disabling `TOTP_ENABLED` is a documented exception: record it and the reason
in the instance's control matrix (row 5). The provisioning smoke test
(`scripts/post-provision-smoke-test.sh`, docs/03 Step 13) reads
`TOTP_ENABLED` from the running gateway container and fails when the deployed
value is not `true`, so the exception shows up on every run until it is
reversed.

## Local end-to-end test

You can exercise the whole flow locally with self-signed certs and a fake email
backend that prints codes to the log.

```bash
# In a server repo checkout:
cp docker-compose.override.yml.example docker-compose.override.yml

# Enable auth with the log email backend and an insecure cookie (no public TLS):
cp apps/auth/.env.example apps/auth/.env
cat >> apps/auth/.env <<'EOF'
EMAIL_BACKEND=log
COOKIE_INSECURE=true
EOF
# set SESSION_SECRET in apps/auth/.env (openssl rand -hex 32), and
# ALLOWED_EMAIL_DOMAINS / AUTH_PUBLIC_URL / COOKIE_DOMAIN for your local domain.

# Uncomment the apps/auth include in docker-compose.yml, then:
docker compose up -d --build
docker compose exec caddy caddy trust    # trust the local CA once

# Add a dummy app guarded by role (apps/demo/demo.caddy with
# `import role "demo" "user" demo:3000`), give yourself the demo app's User
# role on the gateway's admin pages, open the app in a browser, request a
# code, and read it from:
docker compose logs -f auth              # [email:log] ... text="... 123456 ..."
# enter the code, and confirm you land on the demo app.
```

The auth service's own unit + handler tests live in the
[vps-scaffold-auth](https://github.com/uppertoe/vps-scaffold-auth) repo and run
in its CI.

## Security summary

- Single-use, short-lived, attempt-capped codes; stored only as SHA-256 hashes;
  constant-time comparison.
- No user enumeration; per-email and per-IP rate limiting.
- Open-redirect safe (post-login target must be https within the server domain).
- `Secure`/`HttpOnly`/`SameSite=Lax` cookies, tight CSP, no inline scripts.
- Stateless sessions can't be revoked before expiry — keep `SESSION_TTL`
  moderate (default 12h).
- Pin the image by digest (`repo:tag@sha256:…`), as for every image; the
  server repo's `check-image-pins.sh` fails CI on a tag alone.

## Email authenticity (SPF/DKIM/DMARC)

The OTP email IS the login credential's delivery channel, which makes the
sending domain part of the auth system's attack surface: without sender
authentication, a phisher can convincingly spoof "your login code" emails from
your domain. On the domain that `EMAIL_FROM` uses, publish:

- **SPF** — authorize only your actual sender (the SMTP relay in `EMAIL_HOST`):
  `v=spf1 include:<relay-spf> -all`
- **DKIM** — enable signing at the relay and publish its selector key.
- **DMARC** — start with `p=quarantine; rua=mailto:...`, move to `p=reject`
  once the reports are clean.

This also materially improves OTP deliverability — a login email that lands in
spam is an availability incident. Verify after DNS changes with any DMARC
checker; re-check when changing SMTP providers (a stale SPF include silently
breaks both security and delivery). Watch for auth-denial spikes in the weekly
security digest — a burst of 401/429s against the auth host is the signature
of someone probing the login wall.
