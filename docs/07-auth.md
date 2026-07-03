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
  `Remote-Groups` (`admin` or `user`), which Caddy forwards to the app.
- Otherwise `/verify` returns a 302 to the login page.
- The session is a stateless, HMAC-signed cookie scoped to the parent domain, so
  one login covers every app subdomain.

Access rule: a verified email at an **allowed domain** is a regular user; an
email on the **admin whitelist** is an admin. The only persisted state is
single-use OTP codes (SHA-256 hashed) and optional admin TOTP secrets, in a
small SQLite file — no Postgres or Redis.

## Enabling it

The server repo (from `server-instance-template`) ships the wiring under
`apps/auth/`. It is **opt-in** so an unconfigured server never crash-loops on
deploy.

1. Configure secrets:
   ```bash
   cp apps/auth/.env.example apps/auth/.env
   $EDITOR apps/auth/.env          # set SESSION_SECRET, ALLOWED_EMAIL_DOMAINS,
                                    # ADMIN_EMAILS, EMAIL_* etc.
   openssl rand -hex 32            # value for SESSION_SECRET
   ```
2. Uncomment the auth include in the root `docker-compose.yml`:
   ```yaml
   include:
     - scaffold/docker/caddy.base.yml
     - apps/auth/docker-compose.yml   # ← uncomment this
   ```
3. Point a DNS record for `auth.<your-domain>` at the server (so Caddy can issue
   its certificate), then deploy (`~/deploy` on the server, or
   `docker compose up -d`).

`apps/auth/.env` is gitignored and reset to mode 600 by the deploy helper.

## Protecting an app

Add `import protected` to the app's Caddy snippet:

```caddyfile
# apps/dashboard/dashboard.caddy
dashboard.{$DOMAIN} {
    import protected
    reverse_proxy dashboard:3000
}
```

The `(protected)` snippet is defined in `apps/auth/auth.caddy`; because Caddy
concatenates every `apps/*/*.caddy` into one Caddyfile, any app can import it.
Protected apps read identity from the `Remote-User` / `Remote-Email` /
`Remote-Groups` request headers and do their own per-feature authorization.

> **Requires the auth service enabled.** `import protected` (and the
> `auth.{$DOMAIN}` login site) route to the `auth` container. The snippet is
> always defined, so Caddy starts fine — but protected routes return `502` until
> you [enable auth](#enabling-it).

> **Trust model.** Apps trust these headers because only Caddy can reach them —
> apps publish no host ports, and `forward_auth`'s `copy_headers` clears any
> client-supplied `Remote-User` / `Remote-Email` / `Remote-Groups` and replaces
> them with the auth service's values, removing them entirely when the service
> doesn't set one. So a client **cannot** smuggle a forged `Remote-Groups: admin`
> past a non-admin (or unauthenticated) response. Never expose a protected app
> directly, and only trust these three header names.

## Protecting a path

`import protected` guards an entire site block. To protect only part of an app —
say an `/admin` area while the rest stays public — wrap the protected routes in a
`handle` with a path matcher and import the snippet there:

```caddyfile
# apps/blog/blog.caddy
blog.{$DOMAIN} {
    # Authenticated: /admin and everything under it
    handle /admin/* {
        import protected
        reverse_proxy blog:3000
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
        import protected
        reverse_proxy app:3000
    }
}
```

## Admin two-factor (default on)

Email codes inherit the security of the user's inbox. For the higher-trust admin
tier TOTP is required by default (`TOTP_ENABLED=true` in the template
`apps/auth/.env.example`). Admins are enrolled on first login (shown an
`otpauth://` URL for their authenticator app) and challenged for a code
thereafter. Regular users stay code-only.

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
in the instance's control matrix (row 5).

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

# Add a dummy protected app (apps/demo/demo.caddy with `import protected`),
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
- Pin the image to a version tag in production rather than `:latest`.
