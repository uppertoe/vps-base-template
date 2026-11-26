#!/usr/bin/env bash
#
# ci-forward-auth-test.sh — regression guard for the role guard, the security
# lynchpin defined by the (role) snippet in apps/auth/auth.caddy.
#
# It stands up the REAL (role) snippet in Caddy in front of a header-echo
# backend, with a controllable mock auth service (so no sign-in is needed),
# and asserts the security properties the whole auth model depends on:
#   1. On a valid session, client-supplied Remote-* headers are replaced by the
#      auth service's values (no spoofing), the guard names its app and role
#      to the auth service whatever the client sent, and the shared session
#      cookie never reaches the app.
#   2. When the auth service omits a header, the client's copy is dropped, not
#      leaked (you can't smuggle Remote-Roles: admin past a response that
#      carries no roles).
#   3. An unauthenticated guarded request is 302-redirected to sign-in, and a
#      spoofed identity header does not bypass that.
#   4. A session cookie the auth service renews reaches the browser.
#   5. Path scoping works: a public path is not gated.
#
# Caddy is the image pinned in scaffold/docker/caddy.base.yml, so the test
# runs the Caddy the servers run; the header-echo backend is pinned by digest
# below. No real auth image is needed. This test covers the (role) snippet
# only; the gateway's own end-to-end suite (the gateway-chain job, run where
# .scaffold-server.yml sets gateway_chain: true) is the authoritative test of
# role_gate, role_redir and the gateway's decisions.

set -euo pipefail

# The server repo root: this file is installed at <server>/scaffold/scripts/server/,
# so three levels up, unless the calling shim says otherwise.
ROOT_DIR="${SERVER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
AUTH_CADDY="$ROOT_DIR/apps/auth/auth.caddy"
NET=fa-ci-net
GW_PORT=18091
WORK=""

cleanup() {
  docker rm -f fa-ci-gw fa-ci-auth fa-ci-whoami >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  [ -n "$WORK" ] && rm -rf "$WORK"
  return 0
}
trap cleanup EXIT
cleanup  # pre-clean any leftovers from a previous run (WORK not yet created)

WORK="$(mktemp -d)"
[ -f "$AUTH_CADDY" ] || { echo "missing $AUTH_CADDY" >&2; exit 1; }

# The Caddy under test is the one the servers run.
CADDY_BASE="$ROOT_DIR/scaffold/docker/caddy.base.yml"
CADDY_IMAGE="$(grep -oE 'image: *caddy:[^ ]+@sha256:[0-9a-f]{64}' "$CADDY_BASE" 2>/dev/null | head -1 | sed 's/^image: *//')"
[ -n "$CADDY_IMAGE" ] || { echo "no digest-pinned caddy image found in $CADDY_BASE (is the scaffold submodule checked out?)" >&2; exit 1; }
# Header-echo backend, pinned by digest (multi-arch index of traefik/whoami v1.11.0).
WHOAMI_IMAGE="traefik/whoami:v1.11.0@sha256:200689790a0a0ea48ca45992e0450bc26ccab5307375b41c84dfc4f2475937ab"

# Mock auth. The guard forwards the original request (cookies included) to
# /verify with X-Auth-App and X-Auth-Role; the mock admits only when they name
# the app and role the guard was given, and decides from a test cookie.
cat > "$WORK/auth.Caddyfile" <<'EOF'
{
	admin off
	auto_https off
}
:8080 {
	@full {
		path /verify
		header X-Auth-App app
		header X-Auth-Role user
		header_regexp Cookie test_session=full
	}
	handle @full {
		header Remote-User realuser@example.com
		header Remote-Email realuser@example.com
		header Remote-Roles user
		respond 200
	}
	@partial {
		path /verify
		header X-Auth-App app
		header X-Auth-Role user
		header_regexp Cookie test_session=partial
	}
	handle @partial {
		header Remote-User realuser@example.com
		respond 200
	}
	@renewed {
		path /verify
		header X-Auth-App app
		header X-Auth-Role user
		header_regexp Cookie test_session=renew
	}
	handle @renewed {
		header Remote-User realuser@example.com
		header Set-Cookie "vps_auth_session=renewed; Path=/; HttpOnly; Secure"
		respond 200
	}
	@named {
		path /verify
		header X-Auth-App app
		header X-Auth-Role user
	}
	handle @named {
		redir https://auth.example.com/login?rd={http.request.header.X-Forwarded-Uri} 302
	}
	handle {
		respond "the guard did not name its app and role" 403
	}
}
EOF

# Gateway imports the REAL (role) snippet and uses it to guard /admin/*.
cat > "$WORK/gw.Caddyfile" <<'EOF'
{
	admin off
	auto_https off
}
import /srv/auth.caddy
http://fa.test {
	handle /admin/* {
		import role "app" "user" whoami:80
	}
	handle {
		reverse_proxy whoami:80
	}
}
EOF

docker network create "$NET" >/dev/null
docker run -d --name fa-ci-whoami --network "$NET" --network-alias whoami "$WHOAMI_IMAGE" >/dev/null
docker run -d --name fa-ci-auth --network "$NET" --network-alias auth \
  -v "$WORK/auth.Caddyfile:/etc/caddy/Caddyfile:ro" "$CADDY_IMAGE" >/dev/null
docker run -d --name fa-ci-gw --network "$NET" -p "$GW_PORT:80" -e DOMAIN=example.com \
  -v "$WORK/gw.Caddyfile:/etc/caddy/Caddyfile:ro" \
  -v "$AUTH_CADDY:/srv/auth.caddy:ro" "$CADDY_IMAGE" >/dev/null

# Wait for the gateway to answer.
ready=0
for _ in $(seq 1 20); do
  if curl -fsS -o /dev/null -H "Host: fa.test" "http://127.0.0.1:$GW_PORT/" 2>/dev/null; then ready=1; break; fi
  sleep 1
done
[ "$ready" = 1 ] || { echo "gateway did not become ready" >&2; docker logs fa-ci-gw >&2 || true; exit 1; }

base="http://127.0.0.1:$GW_PORT"
fail=0
check() { if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1" >&2; fail=1; fi; }

echo "1. authenticated request replaces spoofed identity with the auth values"
body="$(curl -s -H "Host: fa.test" -H "Cookie: vps_auth_session=estate-secret; test_session=full" \
  -H "Remote-User: attacker@evil.com" -H "Remote-Roles: spoofed-admin" \
  -H "X-Auth-App: other" -H "X-Auth-Role: admin" "$base/admin/x")"
check "Remote-User comes from auth"      "grep -qi 'Remote-User: realuser@example.com' <<<\"\$body\""
check "Remote-Roles comes from auth"     "grep -qi 'Remote-Roles: user' <<<\"\$body\""
check "spoofed Remote-User is stripped"  "! grep -qi 'attacker@evil.com' <<<\"\$body\""
check "spoofed Remote-Roles is stripped" "! grep -qi 'spoofed-admin' <<<\"\$body\""
check "session cookie does not reach the app"  "! grep -qi 'estate-secret' <<<\"\$body\""
check "the app's other cookies still reach it" "grep -qi 'test_session=full' <<<\"\$body\""

echo "2. header omitted by auth is not satisfiable by a client-supplied copy"
# shellcheck disable=SC2034  # read by the checks, inside eval
body="$(curl -s -H "Host: fa.test" -H "Cookie: test_session=partial" \
  -H "Remote-Roles: admin" -H "Remote-Email: attacker@evil.com" "$base/admin/x")"
check "Remote-User still present"        "grep -qi 'Remote-User: realuser@example.com' <<<\"\$body\""
check "client Remote-Roles not leaked"   "! grep -qiE 'Remote-Roles: admin' <<<\"\$body\""
check "client Remote-Email not leaked"   "! grep -qi 'attacker@evil.com' <<<\"\$body\""

echo "3. unauthenticated guarded request redirects to sign-in; spoof cannot bypass"
code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: fa.test" -H "Remote-Roles: admin" "$base/admin/x")"
check "guarded path returns 302"         "[ '$code' = 302 ]"
# shellcheck disable=SC2034  # read by the checks, inside eval
loc="$(curl -s -D - -o /dev/null -H "Host: fa.test" "$base/admin/x" | tr -d '\r' | grep -i '^location:')"
check "redirect preserves return URL"    "grep -qi 'rd=/admin/x' <<<\"\$loc\""

echo "4. a renewed session cookie reaches the browser"
# shellcheck disable=SC2034  # read by the checks, inside eval
hdrs="$(curl -s -D - -o /dev/null -H "Host: fa.test" -H "Cookie: test_session=renew" "$base/admin/x" | tr -d '\r')"
check "renewed Set-Cookie is forwarded"  "grep -qi '^set-cookie: vps_auth_session=renewed' <<<\"\$hdrs\""

echo "5. public path is not gated"
code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: fa.test" "$base/")"
check "public path returns 200"          "[ '$code' = 200 ]"

if [ "$fail" = 0 ]; then
  echo "role guard security checks passed."
else
  echo "role guard security checks FAILED" >&2
  exit 1
fi
