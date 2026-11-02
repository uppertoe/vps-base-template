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
# 2. The route lint. Fixture snippets exercise the open-path rule: in a site
#    that has a guard, a handle, handle_path or route block that serves
#    without a guard must carry "# scaffold-lint: open-path -- <paths>:
#    <reason>", which route-access.tsv then lists as a public row. Cases:
#    an undeclared open handle fails; the marker inside the handle, above it
#    and above its named matcher passes and lands in the table; a nested
#    route under a marked handle passes; a guard in a nested route covers the
#    enclosing handle; a guard in a sibling handle covers nothing; a site
#    with no guard is not checked; handle_errors is not a door; a malformed
#    marker and a marker outside a site fail.
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

# --- 2. the open-path rule ------------------------------------------------------
# render_case <name> <expect: pass|fail> [<grep pattern required on stderr>]
# with the snippet on stdin. On a pass, the rendered route-access.tsv is left
# at $work/<name>-out/route-access.tsv for the row checks below.
render_case() {
  local name="$1" expect="$2" want="${3:-}" rc=0
  local root="$work/$name"
  mkdir -p "$root/apps/app"
  cat > "$root/apps/app/app.caddy"
  bash "$renderer" "$root" "$root-out" >/dev/null 2> "$root.err" || rc=$?
  if [[ "$expect" == pass ]]; then
    if [[ $rc -eq 0 ]]; then pass "lint: $name renders"; else fail "lint: $name should render; stderr:"; cat "$root.err" >&2; fi
  else
    if [[ $rc -ne 0 ]] && grep -q -- "$want" "$root.err"; then
      pass "lint: $name is refused ($want)"
    else
      fail "lint: $name should be refused with '$want'; rc=$rc stderr:"; cat "$root.err" >&2
    fi
  fi
}
# expect_row <name> <tab-separated row>
expect_row() {
  if grep -qxF -- "$2" "$work/$1-out/route-access.tsv"; then
    pass "table: $1 lists $(printf '%s' "$2" | cut -f2-)"
  else
    fail "table: $1 lacks the row '$2'; table is:"; cat "$work/$1-out/route-access.tsv" >&2
  fi
}
open_err='has a gate, but this block serves without one'

# An open handle beside a gate, with nothing to say it is meant.
render_case undeclared fail "$open_err" <<'EOF'
app.{$DOMAIN} {
	@public path /healthz /static/*
	handle @public {
		reverse_proxy app:8080 {
			import strip_public
		}
	}
	handle {
		import protected_domains "example.org" app:8080
	}
}
EOF

# The marker inside the handle.
render_case marker-inside pass <<'EOF'
app.{$DOMAIN} {
	@public path /healthz /static/*
	handle @public {
		# scaffold-lint: open-path -- /healthz /static/*: the health check and the assets
		reverse_proxy app:8080 {
			import strip_public
		}
	}
	handle {
		import protected_domains "example.org" app:8080
	}
}
EOF
expect_row marker-inside $'app.{$DOMAIN}\tpublic\t/healthz /static/*: the health check and the assets'
expect_row marker-inside $'app.{$DOMAIN}\tdomains\texample.org'

# The marker above the handle, with the named matcher between.
render_case marker-above-matcher pass <<'EOF'
app.{$DOMAIN} {
	# scaffold-lint: open-path -- /feeds/*.json: the feed checks its own bearer token
	@feed path /feeds/*.json
	handle @feed {
		reverse_proxy app:8080 {
			import strip_public
		}
	}
	handle {
		import protected_domains "example.org" app:8080
	}
}
EOF
expect_row marker-above-matcher $'app.{$DOMAIN}\tpublic\t/feeds/*.json: the feed checks its own bearer token'

# A marked handle whose proxy sits in a nested route (the strip-then-proxy
# shape), and the marker written directly above the handle line.
render_case nested-route-under-marked-handle pass <<'EOF'
app.{$DOMAIN} {
	@public path / /Q/*
	# scaffold-lint: open-path -- / /Q/*: the public view
	handle @public {
		route {
			import strip_client_identity
			reverse_proxy app:8080 {
				import strip_auth_cookie
			}
		}
	}
	handle {
		import protected_groups "editors" app:8080
	}
}
EOF
expect_row nested-route-under-marked-handle $'app.{$DOMAIN}\tpublic\t/ /Q/*: the public view'

# A guard inside a nested route covers the file_server that follows it in the
# enclosing handle (the hand-written forward_auth shape).
render_case guard-in-nested-route pass <<'EOF'
app.{$DOMAIN} {
	root * /srv/www/app
	handle /staff/* {
		route {
			import strip_client_identity
			forward_auth auth:8080 {
				uri /verify
				copy_headers Remote-User Remote-Email Remote-Groups
				header_up X-Auth-Policy "domains=example.org"
			}
		}
		file_server
	}
	handle {
		# scaffold-lint: open-path -- /*: the public pages
		file_server
	}
}
EOF

# A guard inside a sibling handle says nothing about the open one.
render_case guard-in-sibling-handle fail "$open_err" <<'EOF'
app.{$DOMAIN} {
	route {
		handle /admin/* {
			import protected_admin app:8080
		}
		handle {
			reverse_proxy app:8080 {
				import strip_public
			}
		}
	}
}
EOF

# A site with no guard is governed by the public marker alone.
render_case no-guard-not-checked pass <<'EOF'
# scaffold-lint: public -- the feed checks its own token
app.{$DOMAIN} {
	@feed path /feed.json
	handle @feed {
		reverse_proxy app:8080 {
			import strip_public
		}
	}
	handle {
		respond 404
	}
}
EOF

# Error pages are not a door.
render_case handle-errors-exempt pass <<'EOF'
app.{$DOMAIN} {
	handle_errors {
		@missing expression {err.status_code} == 404
		handle @missing {
			root * /srv/www/app
			rewrite * /404.html
			file_server
		}
	}
	import protected_domains "example.org" app:8080
}
EOF

# The marker must name the paths and give a reason.
render_case marker-without-reason fail 'the marker must read' <<'EOF'
app.{$DOMAIN} {
	handle /healthz {
		# scaffold-lint: open-path -- /healthz
		respond 200
	}
	handle {
		import protected_domains "example.org" app:8080
	}
}
EOF

# route-groups.tsv: a guard group is two columns, a scaffold-groups marker
# group carries "declared" as a third; a group that is both appears in both
# forms.
render_case groups-declared pass <<'EOF'
# scaffold-groups: insights-admins editors -- the app's admin pages
app.{$DOMAIN} {
	import protected_groups "editors" app:8080
}
EOF
for row in $'editors\tapp.{$DOMAIN}' $'editors\tapp.{$DOMAIN}\tdeclared' $'insights-admins\tapp.{$DOMAIN}\tdeclared'; do
  if grep -qxF -- "$row" "$work/groups-declared-out/route-groups.tsv"; then
    pass "groups: lists $(printf '%s' "$row" | tr '\t' ' ')"
  else
    fail "groups: lacks the row '$row'; table is:"; cat "$work/groups-declared-out/route-groups.tsv" >&2
  fi
done
if grep -qxF -- $'insights-admins\tapp.{$DOMAIN}' "$work/groups-declared-out/route-groups.tsv"; then
  fail "groups: a marker-only group must not appear in the two-column guard form"
fi

# The marker belongs inside a site.
render_case marker-outside-site fail 'belongs inside a site block' <<'EOF'
# scaffold-lint: open-path -- /healthz: the health check
app.{$DOMAIN} {
	import protected_domains "example.org" app:8080
}
EOF

echo
if [[ $failures -gt 0 ]]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all renderer checks passed"
