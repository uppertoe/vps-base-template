#!/usr/bin/env bash
# Offline checks for the Caddy renderer (docker/render-caddy-routes.sh) and
# the global block run-caddy.sh assembles, run by CI's lint job and by hand:
#
#   bash docker/tests/test-render-caddy-routes.sh
#
# 1. The access-log token filter. The renderer stamps every site with a filter
#    that replaces a bearer token in the request line, the Referer, htmx's
#    Hx-Current-Url and a redirect's Location; run-caddy.sh puts the same
#    filter on Caddy's default logger. The two are extracted here and must be
#    identical, and the regex is then run through Go's regexp package, which
#    is the RE2 engine Caddy uses, against the token shapes the estate has
#    (a path token, a token with a file extension, a token inside a
#    percent-encoded rd= value) and against ordinary URLs that must stay
#    readable.
#
# Go is needed for part 1 (it is on every GitHub-hosted runner); the test
# fails plainly if it is missing rather than pretending to pass.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
docker_dir="$(dirname "$here")"
renderer="$docker_dir/render-caddy-routes.sh"
run_caddy="$docker_dir/run-caddy.sh"

work="$(mktemp -d)"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok: $*"; }

# Render one minimal public site so the per-site log block can be read back
# from the bundle exactly as a deployment would receive it.
mkdir -p "$work/fixture/apps/demo"
cat > "$work/fixture/apps/demo/demo.caddy" <<'EOF'
# scaffold-lint: public -- a test fixture
demo.{$DOMAIN} {
	reverse_proxy demo:8080 {
		import strip_public
	}
}
EOF
bash "$renderer" "$work/fixture" "$work/fixture-out" >/dev/null

# --- 1. the token filter -----------------------------------------------------
# Field lines look like:  <field> regexp <pattern> <replacement>
# The pattern has no spaces, so the last two words are pattern and replacement.
extract_filter() {
  grep -E '^[[:space:]]*(request>uri|request>headers>Referer|request>headers>Hx-Current-Url|resp_headers>Location) regexp ' "$1" \
    | sed -E 's/^[[:space:]]+//' | sort
}
extract_filter "$work/fixture-out/apps.caddy" > "$work/filter.renderer"
extract_filter "$run_caddy" > "$work/filter.run-caddy"

if [[ "$(wc -l < "$work/filter.renderer")" -ne 4 ]]; then
  fail "renderer: expected four filtered fields, found $(wc -l < "$work/filter.renderer")"
fi
if cmp -s "$work/filter.renderer" "$work/filter.run-caddy"; then
  pass "renderer and run-caddy.sh carry the same four log filter fields"
else
  fail "renderer and run-caddy.sh log filters differ:"
  diff "$work/filter.renderer" "$work/filter.run-caddy" >&2 || true
fi

# Every field must use one and the same pattern and replacement.
awk '{ print $(NF-1), $NF }' "$work/filter.renderer" | sort -u > "$work/filter.unique"
if [[ "$(wc -l < "$work/filter.unique")" -ne 1 ]]; then
  fail "the four fields do not share one regex and replacement"
fi
pattern="$(awk '{ print $1 }' "$work/filter.unique")"
replacement="$(awk '{ print $2 }' "$work/filter.unique")"

if ! command -v go >/dev/null 2>&1; then
  fail "go is not installed; the regex cases cannot be run (Caddy's regexp filter is Go RE2)"
else
  cat > "$work/redact.go" <<'EOF'
package main

import (
	"bufio"
	"fmt"
	"os"
	"regexp"
	"strings"
)

// Reads "input<TAB>expected" lines on stdin, applies the filter the way
// Caddy's regexp log filter does (ReplaceAllString with ${n} expansion) and
// prints one line per case. Exit status 1 if any case differs.
func main() {
	re, err := regexp.Compile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, "regex does not compile:", err)
		os.Exit(2)
	}
	bad := 0
	sc := bufio.NewScanner(os.Stdin)
	for sc.Scan() {
		line := sc.Text()
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "\t", 2)
		got := re.ReplaceAllString(parts[0], os.Args[2])
		if got == parts[1] {
			fmt.Printf("ok: %s -> %s\n", parts[0], got)
		} else {
			fmt.Printf("FAIL: %s -> %s (expected %s)\n", parts[0], got, parts[1])
			bad++
		}
	}
	if bad > 0 {
		os.Exit(1)
	}
}
EOF
  tok='0123456789abcdef0123456789abcdef01234567'   # 40 hex, the air-db and roster shape
  cases="$work/cases.tsv"
  {
    # A token as a whole path segment (air-db editing door).
    printf '/edit/%s\t/edit/REDACTED\n' "$tok"
    # The same token inside the login redirect's percent-encoded rd= value,
    # with a query string following it: the delimiters are %2F and %3F.
    printf '/login?rd=https%%3A%%2F%%2Fdb.example%%2Fedit%%2F%s%%3Fx%%3D1\t/login?rd=https%%3A%%2F%%2Fdb.example%%2Fedit%%2FREDACTED%%3Fx%%3D1\n' "$tok"
    # The redirect to the login page as the Location header records it: the
    # token ends the value.
    printf 'https://auth.example/login?rd=https%%3A%%2F%%2Fdb.example%%2Fedit%%2F%s\thttps://auth.example/login?rd=https%%3A%%2F%%2Fdb.example%%2Fedit%%2FREDACTED\n' "$tok"
    # The post-sign-in redirect's Location, decoded.
    printf 'https://db.example/edit/%s\thttps://db.example/edit/REDACTED\n' "$tok"
    # A token carrying a file extension (the roster's per-consultant calendar
    # feed), plain and percent-encoded.
    printf '/on-call/calendar/12/%s.ics\t/on-call/calendar/12/REDACTED.ics\n' "$tok"
    printf '/login?rd=https%%3A%%2F%%2Froster.example%%2Fon-call%%2Fcalendar%%2F12%%2F%s.ics%%3Fv%%3D2\t/login?rd=https%%3A%%2F%%2Froster.example%%2Fon-call%%2Fcalendar%%2F12%%2FREDACTED.ics%%3Fv%%3D2\n' "$tok"
    # A token as a query value.
    printf '/feed?token=%s&x=1\t/feed?token=REDACTED&x=1\n' "$tok"
    # Ordinary URLs that must stay readable: a page slug under 16 characters,
    # a fingerprinted asset (a dot precedes the hash), a short ?v= build tag,
    # a six-digit code, the rd= of the login page itself.
    printf '/server/the-login-wall/\t/server/the-login-wall/\n'
    printf '/static/app.9f3a1c2b4d5e6f70a1b2c3d4e5f6a7b8.css\t/static/app.9f3a1c2b4d5e6f70a1b2c3d4e5f6a7b8.css\n'
    printf '/coffee.css?v=9f3a1c2b\t/coffee.css?v=9f3a1c2b\n'
    printf '/verify?code=123456\t/verify?code=123456\n'
    printf '/login?rd=https%%3A%%2F%%2Fcaffeine.example%%2Forders%%2F\t/login?rd=https%%3A%%2F%%2Fcaffeine.example%%2Forders%%2F\n'
    # Known over-redaction, kept as is on purpose: a slug of 16 or more
    # URL-safe characters standing as a whole segment is shaped like a token
    # and is blanked too (the design-docs pages, long drug slugs). The filter
    # is shape-based and is not widened or narrowed for it.
    printf '/server/data-backups-and-logs/\t/server/REDACTED/\n'
  } > "$cases"
  if (cd "$work" && GOFLAGS=-mod=mod go run ./redact.go "$pattern" "$replacement" < "$cases"); then
    pass "token filter regex handles every case"
  else
    fail "token filter regex cases"
  fi
fi

echo
if [[ $failures -gt 0 ]]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all renderer checks passed"
