# Sveltia CMS OAuth relay (optional templated app)

Backs the in-browser [Sveltia CMS](https://github.com/sveltia/sveltia-cms) on
Hugo (or any Git-backed) sites. Sveltia commits to GitHub over the API and needs
a token; the `code`→token exchange requires the OAuth App **client secret**,
which can't live in browser JS. This relay does just that exchange and hands the
token to the CMS popup via `postMessage`.

**One relay serves every site.** The token is the editor's own, so it works on
any repo they can reach — every site points its CMS config at the same
`cms-auth.<DOMAIN>`. Source/image: `ghcr.io/uppertoe/sveltia-cms-auth` (a small
stateless Go service; the token is only ever posted to an origin on an explicit
allow-list, never `'*'`).

It is **public** by design (GitHub redirects a browser to `/callback`), so it is
**not** behind the login wall — protection is GitHub OAuth + the origin
allow-list.

This is an **opt-in templated app**: copy `docker/cms-auth/` into your server
repo's `apps/cms-auth/` and wire it up.

## Enable on a server repo

1. **GitHub OAuth App** — github.com → Settings → Developer settings → OAuth Apps
   → New OAuth App. Homepage `https://cms-auth.<DOMAIN>`, **Authorization
   callback URL** `https://cms-auth.<DOMAIN>/callback`. Note the client id, then
   generate a client secret.
2. **DNS** `cms-auth.<DOMAIN>` → the host.
3. **Copy the template:** `cp -r scaffold/docker/cms-auth apps/cms-auth`.
4. **Pin the image** — replace `REPLACE_WITH_CURRENT_DIGEST` in
   `apps/cms-auth/docker-compose.yml` with the current digest
   (`docker buildx imagetools inspect ghcr.io/uppertoe/sveltia-cms-auth:latest`).
   Renovate keeps it current thereafter.
5. `cp apps/cms-auth/.env.example apps/cms-auth/.env` and fill
   `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, and `ALLOWED_ORIGINS` (the CMS
   admin-page origins, e.g. `https://handbook.<DOMAIN>,https://<DOMAIN>`).
6. Add the include line to the root `docker-compose.yml`:
   `- apps/cms-auth/docker-compose.yml`, then
   `bash scaffold/docker/render-caddy-routes.sh && git add .generated apps/cms-auth`.
7. Deploy.

## Point a site at it

In each site's `static/admin/config.yml` (served at `<site>/admin/`):

```yaml
backend:
  name: github
  repo: your-org/your-site
  branch: main
  base_url: https://cms-auth.<DOMAIN>
  auth_scope: repo          # public_repo if the source repo is public
```

Then add that site's origin to `ALLOWED_ORIGINS`. Gate the `/admin/` page behind
`import protected_admin` (or `protected_domains`) for defence-in-depth if the
site is otherwise public.
