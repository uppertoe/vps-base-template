# Authentication (email one-time-code)

The scaffold can put a passwordless login wall in front of any app using
[vps-scaffold-auth](https://github.com/uppertoe/vps-scaffold-auth) — a small Go
`forward_auth` gateway. Users enter their email, receive a 6-digit code, type it
in, and get a session. No passwords, no passkeys, no third-party identity
provider.

It runs as a normal app under `apps/auth/`, consumed as a prebuilt image from
`ghcr.io/uppertoe/vps-scaffold-auth`. The image is public, so the VPS pulls it
with no credentials.

## How it works

```
browser ─▶ Caddy (app.example.com)
              │  import protected ─▶ forward_auth GET auth:8080/verify
              │                        ├─ valid session → 200 + Remote-User/Email/Groups → app
              │                        └─ no session    → 302 → auth.example.com/login
              ▼
           auth.example.com  ── email → 6-digit code → HMAC-signed session cookie (.example.com)
```

- Caddy calls `GET /verify` on every request to a protected app.
- A valid session returns `200` plus `Remote-User`, `Remote-Email`, and
  `Remote-Groups`, which Caddy forwards to the app. `Remote-Groups` carries
  the gateway groups the person belongs to.
- Otherwise `/verify` returns a 302 to the login page.
- The session is a stateless, HMAC-signed cookie scoped to the parent domain, so
  one login covers every app subdomain.

Access rule: a verified email at an **allowed domain** is a regular user; an
email on the **admin whitelist** is an admin. A guard can require a group, an
email domain, or any signed-in user (the snippet catalogue is in the server
repo's `apps/auth/auth.caddy`), and the route renderer lists what each site
requires in `.generated/caddy/route-access.tsv`. The service keeps its state
in a small SQLite file — no Postgres or Redis.

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

Add `import protected` to the app's Caddy snippet:

```caddyfile
# apps/dashboard/dashboard.caddy
dashboard.{$DOMAIN} {
    import protected dashboard:3000
}
```

The `(protected)` snippet is defined in `apps/auth/auth.caddy`; because Caddy
renders every `apps/*/*.caddy` into one generated route bundle, any app can import it.
Protected apps read identity from the `Remote-User` / `Remote-Email` /
`Remote-Groups` request headers and do their own per-feature authorization.

> **Requires the auth service enabled.** `import protected` (and the
> `auth.{$DOMAIN}` login site) route to the `auth` container. The snippet is
> always defined, so Caddy starts fine — but protected routes return `502` until
> you [enable auth](#enabling-it).

> **Trust model.** Apps trust these headers because only Caddy should share their
> per-app proxy network — apps publish no host ports, and `forward_auth`'s
> `copy_headers` clears any
> client-supplied `Remote-User` / `Remote-Email` / `Remote-Groups` and replaces
> them with the auth service's values, removing them entirely when the service
> doesn't set one. So a client **cannot** smuggle a forged `Remote-Groups: admin`
> past a non-admin (or unauthenticated) response. Never expose a protected app
> directly, never put unrelated apps on the same proxy network, and only trust
> these three header names.

## Protecting a path

`import protected` guards an entire site block. To protect only part of an app —
say an `/admin` area while the rest stays public — wrap the protected routes in a
`handle` with a path matcher and import the snippet there:

```caddyfile
# apps/blog/blog.caddy
blog.{$DOMAIN} {
    # Authenticated: /admin and everything under it
    handle /admin/* {
        import protected blog:3000
    }
    # Public: everything else
    handle {
        reverse_proxy blog:3000
    }
}
```

Caddy routes each request to exactly one `handle` block — the most specific
matching one — so `/admin/*` requests run `forward_auth` first (an unauthenticated
request gets a `302` to the login page) while every other path skips it. Cover
several prefixes with one matcher when you need to: `handle /admin/* /settings/*`.

To protect everything *except* a few public paths, give the public paths their own
`handle` and make the catch-all the protected one:

```caddyfile
app.{$DOMAIN} {
    handle /healthz {            # public health check
        reverse_proxy app:3000
    }
    handle {                     # everything else requires login
        import protected app:3000
    }
}
```

## Protecting an app with roles

An app can instead declare the roles it has and leave the gateway's admin
pages to decide who holds each one. Guard each `handle` with `import role`,
naming the app and the role its paths need, and declare every role other
than `user` above the site address:

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

Three markers describe the app. They sit on comment lines just above the
site address or inside the site block.

- `# scaffold-roles: <role> "<Label>" ...` declares the app's roles beyond
  `user`, which every app has with the label "User". A role name uses
  lower-case letters, digits, `-` and `_`.
- `# scaffold-app-label: "<Label>"` sets the name the gateway's admin pages
  show. Without it, the gateway shows the app name with its first letter in
  capitals and `-` or `_` read as a space.
- `# scaffold-card-pages: <path> "<Label>" ...` lists the pages a break-glass
  card for the app may open. Each must be an exact path that a `user` guard
  decides, because a card holds only the user role.

An open path is declared with the same `open-path` marker that any gated site
uses (docs/04), and the gateway shows the text after its colon as the reason.
Access from a named network is assigned on the gateway's admin pages, so a
handle with a network matcher has no place in a site guarded by roles.

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
every path the other handles do not name (`*`). An open handle may use a
`path_regexp` matcher instead, and its marker must then list the paths as
exact paths or prefixes ending in `*`. The gateway decides a path as Caddy
does: an exact path first, then the longest prefix, then `*`.

The render fails, naming the file and line, in each of these cases:

- a guard names a role that the snippet does not declare;
- an app has role guards but none for `user`;
- two site blocks use the same app name, in one snippet or in two, or one
  site guards with two apps;
- a site mixes `import role` with an older guard (`protected*`,
  `auth_gate*`, `forward_auth`), which the gateway refuses at every request,
  so the whole site must be migrated at once;
- an open-path marker sits on a catch-all `handle` or at the top level of the
  site, where it would open every path that no other handle names;
- a card page is decided by an open path or by a role other than `user`;
- a handle's matcher is not a path matcher, a path cannot be written as an
  exact path or a prefix ending in `*`, or two handles declare the same path;
- an app-roles marker sits on a site that has no `import role` guard.

A site still guarded by the older guards renders exactly as before and adds
nothing to the manifest.

The auth service reads the manifest once its compose file mounts it, which
the server repos add in this form:

```yaml
    environment:
      - APP_ROLES_FILE=/etc/vps-auth/app-roles.tsv
    volumes:
      - ../../.generated/caddy/app-roles.tsv:/etc/vps-auth/app-roles.tsv:ro
```

### Checking the routes

`docker/check-routes.sh` requests every path the manifest declares, without
signing in, and fails if a guarded path is served or an open path is sent to
the sign-in page. On the server, from `/opt/deploy`, run:

```bash
bash scaffold/docker/check-routes.sh --connect 127.0.0.1 example.org
```

`--connect` sends the requests to the local Caddy while keeping each host
name, and `--insecure` skips the certificate check for a local Caddy with its
own certificate authority. Run the check from outside any network that the
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

# Add a dummy protected app (apps/demo/demo.caddy with `import protected demo:3000`),
# hit it in a browser, request a code, read it from:
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
