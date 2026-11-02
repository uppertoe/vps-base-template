#!/usr/bin/env bash
#
# ci-forward-auth-test.sh — regression guard for the forward_auth security
# lynchpin defined by the (protected) snippet in apps/auth/auth.caddy.
#
# It stands up the REAL (protected) snippet in Caddy in front of a header-echo
# backend, with a controllable mock auth service (so no OTP login is needed),
# and asserts the security properties the whole auth model depends on:
#   1. On a valid session, client-supplied Remote-* headers are replaced by the
#      auth service's values (no spoofing).
#   2. When the auth service omits a header, the client's copy is dropped, not
#      leaked (you can't smuggle Remote-Groups: admin past a non-admin response).
#   3. An unauthenticated protected request is 302-redirected to login, and a
#      spoofed identity header does not bypass that.
#   4. Path scoping works: a public path is not gated.
#
# Uses only caddy:2-alpine + traefik/whoami, so it needs no submodule and no
# real auth image.

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

# Mock auth. forward_auth forwards the original request (cookies included) to
# /verify; the mock decides from the session cookie.
cat > "$WORK/auth.Caddyfile" <<'EOF'
{
	admin off
	auto_https off
}
:8080 {
	@verify path /verify
	handle @verify {
		@full header_regexp Cookie test_session=full
		handle @full {
			header Remote-User realuser@example.com
			header Remote-Email realuser@example.com
			header Remote-Groups admin
			respond 200
		}
		@partial header_regexp Cookie test_session=partial
		handle @partial {
			header Remote-User realuser@example.com
			respond 200
		}
		handle {
			redir https://auth.example.com/?next={http.request.header.X-Forwarded-Uri} 302
		}
	}
}
EOF

# Gateway imports the REAL (protected) snippet and uses it to guard /admin/*.
cat > "$WORK/gw.Caddyfile" <<'EOF'
{
	admin off
	auto_https off
}
import /srv/auth.caddy
http://fa.test {
	handle /admin/* {
		import protected whoami:80
	}
	handle {
		reverse_proxy whoami:80
	}
}
EOF

docker network create "$NET" >/dev/null
docker run -d --name fa-ci-whoami --network "$NET" --network-alias whoami traefik/whoami:latest >/dev/null
docker run -d --name fa-ci-auth --network "$NET" --network-alias auth \
  -v "$WORK/auth.Caddyfile:/etc/caddy/Caddyfile:ro" caddy:2-alpine >/dev/null
docker run -d --name fa-ci-gw --network "$NET" -p "$GW_PORT:80" -e DOMAIN=example.com \
  -v "$WORK/gw.Caddyfile:/etc/caddy/Caddyfile:ro" \
  -v "$AUTH_CADDY:/srv/auth.caddy:ro" caddy:2-alpine >/dev/null

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
body="$(curl -s -H "Host: fa.test" -H "Cookie: test_session=full" \
  -H "Remote-User: attacker@evil.com" -H "Remote-Groups: spoofed-admin" "$base/admin/x")"
check "Remote-User comes from auth"      "grep -qi 'Remote-User: realuser@example.com' <<<\"\$body\""
check "Remote-Groups comes from auth"    "grep -qi 'Remote-Groups: admin' <<<\"\$body\""
check "spoofed Remote-User is stripped"  "! grep -qi 'attacker@evil.com' <<<\"\$body\""
check "spoofed Remote-Groups is stripped" "! grep -qi 'spoofed-admin' <<<\"\$body\""

echo "2. header omitted by auth is not satisfiable by a client-supplied copy"
# shellcheck disable=SC2034  # fetched for its side effect on the mock's log
body="$(curl -s -H "Host: fa.test" -H "Cookie: test_session=partial" \
  -H "Remote-Groups: admin" -H "Remote-Email: attacker@evil.com" "$base/admin/x")"
check "Remote-User still present"        "grep -qi 'Remote-User: realuser@example.com' <<<\"\$body\""
check "client Remote-Groups not leaked"  "! grep -qiE 'Remote-Groups: admin' <<<\"\$body\""
check "client Remote-Email not leaked"   "! grep -qi 'attacker@evil.com' <<<\"\$body\""

echo "3. unauthenticated protected request redirects to login; spoof cannot bypass"
code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: fa.test" -H "Remote-Groups: admin" "$base/admin/x")"
check "protected path returns 302"       "[ '$code' = 302 ]"
# shellcheck disable=SC2034
loc="$(curl -s -D - -o /dev/null -H "Host: fa.test" "$base/admin/x" | tr -d '\r' | grep -i '^location:')"
check "redirect preserves return URL"    "grep -qi 'next=/admin/x' <<<\"\$loc\""

echo "4. public path is not gated"
code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: fa.test" "$base/")"
check "public path returns 200"          "[ '$code' = 200 ]"

if [ "$fail" = 0 ]; then
  echo "forward_auth security checks passed."
else
  echo "forward_auth security checks FAILED" >&2
  exit 1
fi
