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
#    enclosing handle; a guard in a sibling handle covers nothing; a
#    reverse_proxy or file_server at the site's top level beside a
#    handle-scoped guard fails unless marked, and a top-level route guard
#    covers it; a site with no guard is not checked; handle_errors is not a
#    door; a malformed marker and a marker outside a site fail.
#
# 3. Members networks: an app with a scaffold-members marker gets its own
#    internal network to the gateway.
#
# 4. App roles. A site guarded with import role is rendered into
#    app-roles.tsv (render-app-roles.sh); the example from docs/07 is checked
#    against a golden file, and every refusal has a case.
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

# The site block is the outermost frame: a reverse_proxy at the site's top
# level beside a guard that sits only inside a handle answers every path the
# handle does not match, and is refused like an open handle would be.
render_case top-level-proxy-beside-handle-guard fail "$open_err" <<'EOF'
app.{$DOMAIN} {
	handle /admin/* {
		import protected_admin app:8080
	}
	reverse_proxy app:8080 {
		import strip_auth_cookie
	}
}
EOF

# The same shape with a marker above the top-level proxy passes and the
# table lists the open paths.
render_case top-level-proxy-marked pass <<'EOF'
app.{$DOMAIN} {
	handle /admin/* {
		import protected_admin app:8080
	}
	# scaffold-lint: open-path -- /*: the public pages; only /admin/* is gated
	reverse_proxy app:8080 {
		import strip_public
	}
}
EOF
expect_row top-level-proxy-marked $'app.{$DOMAIN}\tpublic\t/*: the public pages; only /admin/* is gated'
expect_row top-level-proxy-marked $'app.{$DOMAIN}\tgroups\tadmin'

# A top-level file_server is refused the same way.
render_case top-level-file-server-beside-handle-guard fail "$open_err" <<'EOF'
app.{$DOMAIN} {
	root * /srv/www/app
	handle /staff/* {
		import protected_domains "example.org" app:8080
	}
	file_server
}
EOF

# A route block at the top level guards the top level, as it guards an
# enclosing handle: the file_server after it is covered.
render_case top-level-route-guard-covers-top-level pass <<'EOF'
app.{$DOMAIN} {
	root * /srv/www/app
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

# --- 3. members networks ------------------------------------------------------
# An app whose snippet carries "# scaffold-members:" gets an internal
# <app>_members network that only the gateway (auth) and that app join; an app
# without the marker gets none; and the marker without apps/auth enabled fails.
members_fixture() {
  local root="$1" with_auth="$2"
  mkdir -p "$root/apps/auth" "$root/apps/cases" "$root/apps/rota"
  {
    printf 'include:\n'
    [[ "$with_auth" == yes ]] && printf '  - apps/auth/docker-compose.yml\n'
    printf '  - apps/cases/docker-compose.yml\n  - apps/rota/docker-compose.yml\n'
  } > "$root/docker-compose.yml"
  for a in auth cases rota; do
    printf 'services:\n  %s:\n    image: example/%s\n' "$a" "$a" > "$root/apps/$a/docker-compose.yml"
    # shellcheck disable=SC2016 # {$DOMAIN} is Caddy's placeholder, written literally
    printf '# scaffold-lint: public -- a test fixture\n%s.{$DOMAIN} {\n\treverse_proxy %s:8080 {\n\t\timport strip_public\n\t}\n}\n' "$a" "$a" > "$root/apps/$a/$a.caddy"
  done
  sed -i.bak '1i\
# scaffold-members: cases_coordinators -- reads these groups members from the gateway
' "$root/apps/cases/cases.caddy" && rm -f "$root/apps/cases/cases.caddy.bak"
}
members_fixture "$work/members" yes
if bash "$renderer" "$work/members" "$work/members-out" >/dev/null 2>"$work/members.err"; then
  nets="$work/members-out/networks.yml"
  auth_block="$(awk '/^  auth:/{f=1;next} /^  [a-z]/{f=0} f' "$nets")"
  cases_block="$(awk '/^  cases:/{f=1;next} /^  [a-z]/{f=0} f' "$nets")"
  rota_block="$(awk '/^  rota:/{f=1;next} /^  [a-z]/{f=0} f' "$nets")"
  if grep -A2 '^      cases_members:$' <<<"$auth_block" | grep -q -- '- auth-members' \
     && ! grep -q 'auth-members' <<<"$cases_block" \
     && grep -q -- '- cases_members' <<<"$cases_block" \
     && ! grep -q -- '_members' <<<"$rota_block" \
     && grep -A1 -q '^  cases_members:$' "$nets" && grep -A1 '^  cases_members:$' "$nets" | grep -q 'internal: true' \
     && ! grep -q 'rota_members' "$nets"; then
    pass "members network: cases and auth share an internal cases_members, where auth is auth-members; rota has none"
  else
    fail "members network not as expected:"; cat "$nets" >&2
  fi
  if grep -q -- '- auth_proxy' <<<"$cases_block"; then
    fail "an app was put on auth_proxy"
  else
    pass "no app joins auth_proxy"
  fi
else
  fail "renderer refused the members fixture: $(cat "$work/members.err")"
fi
members_fixture "$work/members-noauth" no
if bash "$renderer" "$work/members-noauth" "$work/members-noauth-out" >/dev/null 2>"$work/members-noauth.err"; then
  fail "a scaffold-members marker without apps/auth enabled was accepted"
elif grep -q 'apps/auth is not enabled' "$work/members-noauth.err"; then
  pass "a scaffold-members marker without apps/auth fails"
else
  fail "unexpected error: $(cat "$work/members-noauth.err")"
fi

# --- 4. app roles ---------------------------------------------------------------
# A site guarded with import role is rendered into app-roles.tsv, the manifest
# the gateway reads as APP_ROLES_FILE. The golden case is the example in
# docs/07-auth.md "Protecting an app with roles": its caddyfile block is
# rendered as apps/fellows/fellows.caddy and the result must equal the
# manifest block shown below it, so the documentation cannot drift from the
# renderer. Every refusal then has a case of its own.
doc="$(dirname "$docker_dir")/docs/07-auth.md"
# doc_block <fence language> prints the first such fenced block in the section.
doc_block() {
  awk -v lang="$1" '
    /^## Protecting an app with roles/ { sec = 1; next }
    sec && /^## / { exit }
    sec && !inb && $0 == "```" lang { inb = 1; next }
    inb && /^```/ { exit }
    inb { print }
  ' "$doc"
}
mkdir -p "$work/roles-example/apps/fellows"
doc_block caddyfile | grep -v '^# apps/fellows/fellows.caddy$' > "$work/roles-example/apps/fellows/fellows.caddy"
doc_block tsv > "$work/roles-example.golden"
if [[ ! -s "$work/roles-example/apps/fellows/fellows.caddy" || ! -s "$work/roles-example.golden" ]]; then
  fail "manifest: the example and its manifest were not found in docs/07-auth.md"
elif ! bash "$renderer" "$work/roles-example" "$work/roles-example-out" >/dev/null 2>"$work/roles-example.err"; then
  fail "manifest: the docs/07 example does not render: $(cat "$work/roles-example.err")"
elif diff -u "$work/roles-example.golden" <(grep -v '^#' "$work/roles-example-out/app-roles.tsv" | sed '/^$/d') >&2; then
  pass "manifest: the docs/07 example renders to the manifest shown there"
else
  fail "manifest: the docs/07 example differs from the manifest shown there (diff above)"
fi
if head -1 "$work/roles-example-out/app-roles.tsv" | grep -q '^# Generated by scaffold/docker/render-app-roles.sh; do not edit.$'; then
  pass "manifest: the file starts with the generated-file header"
else
  fail "manifest: the generated-file header is missing"
fi
expect_row roles-example $'enquiries.{$DOMAIN}\troles\tenquiries admin'
expect_row roles-example $'enquiries.{$DOMAIN}\troles\tenquiries user'
expect_row roles-example $'enquiries.{$DOMAIN}\tpublic\t/ /faq /privacy: read before a person signs in'

# A site with no role guard leaves the manifest with its header only, and the
# older guards render as before.
if grep -qv '^#' "$work/marker-inside-out/app-roles.tsv"; then
  fail "manifest: a site with older guards produced manifest records"; cat "$work/marker-inside-out/app-roles.tsv" >&2
else
  pass "manifest: a site with older guards adds nothing to it"
fi

# Several addresses, a scheme, a top-level guard, a derived label, a named
# path matcher and a path_regexp open path whose marker lists the patterns.
render_case roles-shapes pass <<'EOF'
https://roster-insights.{$DOMAIN}, roster.{$DOMAIN} {
	@feed path_regexp ^/feeds/staff/[a-z]+\.json$
	handle @feed {
		# scaffold-lint: open-path -- /feeds/staff/*: the app checks the bearer token
		reverse_proxy app:8080 {
			import strip_public
		}
	}
	@about path /about /help/*
	handle @about {
		import role "roster-insights" "user" app:8080
	}
	import role "roster-insights" "user" app:8080
}
EOF
cat > "$work/roles-shapes.golden" <<'EOF'
roster-insights	user	User	roster-insights.{$DOMAIN},roster.{$DOMAIN}
@label	roster-insights	Roster insights
@source	roster-insights	apps/app/app.caddy
@open	roster-insights	/feeds/staff/*	the app checks the bearer token
@path	roster-insights	/about /help/*	user
@path	roster-insights	*	user
EOF
if diff -u "$work/roles-shapes.golden" <(grep -v '^#' "$work/roles-shapes-out/app-roles.tsv" | sed '/^$/d') >&2; then
  pass "manifest: addresses, a top-level guard, a derived label and a path_regexp open path"
else
  fail "manifest: the shapes case differs (diff above)"
fi

# The refusals.
render_case roles-undeclared-role fail 'role "admin" is not declared for app "app"' <<'EOF'
app.{$DOMAIN} {
	handle /admin/* {
		import role "app" "admin" app:8080
	}
	handle {
		import role "app" "user" app:8080
	}
}
EOF
render_case roles-no-user fail 'has role guards but none for the user role' <<'EOF'
# scaffold-roles: admin "Administrator"
app.{$DOMAIN} {
	import role "app" "admin" app:8080
}
EOF
render_case roles-mixed-guards fail 'mixes import role with an older guard' <<'EOF'
app.{$DOMAIN} {
	handle /admin/* {
		import protected_admin app:8080
	}
	handle {
		import role "app" "user" app:8080
	}
}
EOF
render_case roles-open-catch-all fail 'an open-path marker on a catch-all handle' <<'EOF'
app.{$DOMAIN} {
	handle /account/* {
		import role "app" "user" app:8080
	}
	handle {
		# scaffold-lint: open-path -- /*: everything else is public
		reverse_proxy app:8080 {
			import strip_public
		}
	}
}
EOF
render_case roles-open-top-level fail 'an open-path marker at the top level' <<'EOF'
app.{$DOMAIN} {
	handle /account/* {
		import role "app" "user" app:8080
	}
	# scaffold-lint: open-path -- /*: everything else is public
	reverse_proxy app:8080 {
		import strip_public
	}
}
EOF
render_case roles-card-on-open-path fail 'card page / is not under a path guarded by import role "app" "user"' <<'EOF'
# scaffold-card-pages: / "Home"
app.{$DOMAIN} {
	@public path /
	handle @public {
		# scaffold-lint: open-path -- /: the landing page
		reverse_proxy app:8080 {
			import strip_public
		}
	}
	handle {
		import role "app" "user" app:8080
	}
}
EOF
render_case roles-card-on-admin-path fail 'the admin role decides it' <<'EOF'
# scaffold-roles: admin "Administrator"
# scaffold-card-pages: /admin/users "Users"
app.{$DOMAIN} {
	handle /admin/* {
		import role "app" "admin" app:8080
	}
	handle {
		import role "app" "user" app:8080
	}
}
EOF
render_case roles-network-matcher fail 'a handle needs a path matcher' <<'EOF'
app.{$DOMAIN} {
	@office remote_ip 10.0.0.0/8
	handle @office {
		# scaffold-lint: open-path -- /*: open on the office network
		reverse_proxy app:8080 {
			import strip_public
		}
	}
	handle {
		import role "app" "user" app:8080
	}
}
EOF
render_case roles-suffix-pattern fail 'cannot be written in the app-roles manifest' <<'EOF'
app.{$DOMAIN} {
	@css path *.css
	handle @css {
		# scaffold-lint: open-path -- *.css: the styles
		reverse_proxy app:8080 {
			import strip_public
		}
	}
	handle {
		import role "app" "user" app:8080
	}
}
EOF
render_case roles-path-twice fail 'path /admin/\* is already decided' <<'EOF'
# scaffold-roles: admin "Administrator"
app.{$DOMAIN} {
	handle /admin/* {
		import role "app" "admin" app:8080
	}
	@more path /admin/*
	handle @more {
		import role "app" "user" app:8080
	}
}
EOF
render_case roles-two-apps-in-site fail 'guards with two apps' <<'EOF'
app.{$DOMAIN} {
	handle /other/* {
		import role "other" "user" app:8080
	}
	handle {
		import role "app" "user" app:8080
	}
}
EOF
render_case roles-two-sites-one-snippet fail 'app "app" is already declared by the site at' <<'EOF'
app.{$DOMAIN} {
	import role "app" "user" app:8080
}
www.app.{$DOMAIN} {
	import role "app" "user" app:8080
}
EOF
render_case roles-marker-without-guard fail 'carries an app-roles marker but has no import role guard' <<'EOF'
# scaffold-roles: admin "Administrator"
app.{$DOMAIN} {
	import protected app:8080
}
EOF
render_case roles-malformed-guard fail 'the guard must read import role' <<'EOF'
app.{$DOMAIN} {
	import role app user app:8080
}
EOF
render_case roles-malformed-roles-marker fail 'the marker must read: # scaffold-roles:' <<'EOF'
# scaffold-roles: admin
app.{$DOMAIN} {
	import role "app" "user" app:8080
}
EOF
render_case roles-user-declared fail 'the user role is always declared' <<'EOF'
# scaffold-roles: user "Member"
app.{$DOMAIN} {
	import role "app" "user" app:8080
}
EOF
render_case roles-marker-outside-site fail 'an app-roles marker belongs just above a site address' <<'EOF'
# scaffold-roles: admin "Administrator"
(app_snippet) {
	respond 404
}
EOF
# The lint that already refuses an undeclared site still does with role
# guards about: a site with neither a guard nor a marker fails, and a role
# guard counts as the site's guard for the open-path rule.
render_case roles-site-undeclared fail 'declares no access' <<'EOF'
app.{$DOMAIN} {
	reverse_proxy app:8080 {
		import strip_public
	}
}
EOF
render_case roles-open-handle-unmarked fail "$open_err" <<'EOF'
app.{$DOMAIN} {
	handle /healthz {
		respond 200
	}
	handle {
		import role "app" "user" app:8080
	}
}
EOF

# Two snippets that use the same app name.
mkdir -p "$work/roles-two-snippets/apps/one" "$work/roles-two-snippets/apps/two"
for a in one two; do
  # shellcheck disable=SC2016 # {$DOMAIN} is Caddy's placeholder, written literally
  printf '%s.{$DOMAIN} {\n\timport role "shared" "user" %s:8080\n}\n' "$a" "$a" > "$work/roles-two-snippets/apps/$a/$a.caddy"
done
if bash "$renderer" "$work/roles-two-snippets" "$work/roles-two-snippets-out" >/dev/null 2>"$work/roles-two-snippets.err"; then
  fail "two snippets with one app name were accepted"
elif grep -q 'apps/two/two.caddy:1: app "shared" is already declared by the site at .*apps/one/one.caddy:1' "$work/roles-two-snippets.err"; then
  pass "two snippets with one app name are refused"
else
  fail "unexpected error for two snippets: $(cat "$work/roles-two-snippets.err")"
fi

echo
if [[ $failures -gt 0 ]]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all renderer checks passed"
