#!/usr/bin/env bash
# check-routes.sh -- request every path the app-roles manifest declares,
# signed out, and check that Caddy and the gateway answer as it says.
#
#   bash scaffold/docker/check-routes.sh [options] DOMAIN [MANIFEST]
#
#   DOMAIN     the value of {$DOMAIN} in the manifest's hosts (example.org)
#   MANIFEST   the rendered manifest (default .generated/caddy/app-roles.tsv)
#
#   --connect HOST[:PORT]  send every request to this address instead of the
#                          one DNS gives, keeping the host name for TLS and
#                          Host (127.0.0.1 on the box itself)
#   --insecure             do not verify the certificate (a local Caddy with
#                          its own CA, or a certificate still being issued)
#   --scheme http|https    default https
#
# For every app in the manifest, on every host it names, the script asks for
# one path per pattern: the path itself for an exact pattern, a path below a
# prefix ("/admin/*" asks for /admin/scaffold-route-check) and, for "*", a
# path no other line names. Card pages are asked for as they are written.
# Beside each open pattern it also asks for one path that the pattern does
# not cover and a guarded line decides: below an exact open path ("/faq"
# asks for /faq/scaffold-route-check-beside) and, for a prefix ending in "/*",
# the prefix without its slash ("/static/*" asks for /static), so that an
# open matcher wider than the manifest says is caught. The expectations are:
#
#   * a path that needs a role answers a redirect to the gateway's /login
#     page, because the request carries no session;
#   * an open path answers anything below 500 except a redirect to /login (a
#     404 is fine: the path below a prefix is made up);
#   * no answer, or a 5xx, fails either kind.
#
# A path a role guards that is served without signing in, or an open path
# that is sent to sign in, therefore fails the check, and the script exits 1.
#
# The check runs signed out only. It cannot say whether a session holding
# each role reaches its paths, because it cannot mint a session; that needs
# the gateway to issue a test session per role and is left as a follow-up.
# Run it from outside any network the gateway admits by itself (a network
# assignment can grant a role without sign-in), or such a path is reported
# as served without sign-in.
set -euo pipefail

usage() { sed -n '4,16p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

connect=""; insecure=0; scheme=https
while [[ $# -gt 0 ]]; do
  case "$1" in
    --connect) connect="${2:?--connect needs HOST[:PORT]}"; shift 2 ;;
    --insecure) insecure=1; shift ;;
    --scheme) scheme="${2:?--scheme needs http or https}"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "check-routes: unknown option $1" >&2; usage ;;
    *) break ;;
  esac
done
[[ $# -ge 1 && $# -le 2 ]] || usage
domain="$1"
manifest="${2:-.generated/caddy/app-roles.tsv}"
[[ "$scheme" == http || "$scheme" == https ]] || usage
[[ -f "$manifest" ]] || { echo "check-routes: no manifest at $manifest" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "check-routes: curl is not installed" >&2; exit 2; }

port=443; [[ "$scheme" == http ]] && port=80
curl_opts=(-s -o /dev/null --max-time 10 --connect-timeout 5 -A 'scaffold-check-routes'
           -H 'Accept: text/html' -w '%{http_code}\t%{redirect_url}')
[[ $insecure -eq 1 ]] && curl_opts+=(-k)
if [[ -n "$connect" ]]; then
  [[ "$connect" == *:* ]] || connect="$connect:$port"
  curl_opts+=(--connect-to "::$connect")
fi

# One line per request: host, path, expectation (open or guarded) and what
# the manifest says about it (the role, or "open"). The path chosen for each
# pattern is checked against the gateway's own rule (an exact pattern first,
# then the longest prefix, then "*"), so the request tests the line it is
# meant to; a pattern whose path another line decides is reported and skipped.
plan() {
  awk -F'\t' -v domain="$domain" '
    /^[[:space:]]*(#|$)/ { next }
    $1 !~ /^@/ && NF == 4 {
      if ($2 == "user") { hosts[$1] = $4 }
      if (!($1 in seen)) { seen[$1] = 1; order[++napps] = $1 }
      next
    }
    ($1 == "@path" || $1 == "@open") && NF == 4 {
      n = ++nl[$2]; kind[$2, n] = ($1 == "@open") ? "open" : "guarded"
      pats[$2, n] = $3; value[$2, n] = ($1 == "@open") ? "open" : $4
      next
    }
    $1 == "@card-page" && NF == 4 { nc[$2]++; card[$2, nc[$2]] = $3; next }
    function decide(app, path,    i, k, m, t, s, best, score, pre) {
      best = 0; score = -1
      for (i = 1; i <= nl[app]; i++) {
        m = split(pats[app, i], t, " ")
        for (k = 1; k <= m; k++) {
          s = -1
          if (t[k] == "*") { s = 0 }
          else if (t[k] ~ /\*$/) { pre = substr(t[k], 1, length(t[k]) - 1); if (substr(path, 1, length(pre)) == pre) { s = 1 + length(pre) } }
          else if (t[k] == path) { s = 1048576 }
          if (s > score) { score = s; best = i }
        }
      }
      return best
    }
    # A path just outside an open pattern, or "" when there is none to ask.
    function beside_path(p,    pre) {
      if (p == "*" || p == "/" || p == "/*") { return "" }
      if (p ~ /\*$/) {
        pre = substr(p, 1, length(p) - 1)
        return (pre ~ /.\/$/) ? substr(pre, 1, length(pre) - 1) : ""
      }
      return p (p ~ /\/$/ ? "" : "/") "scaffold-route-check-beside"
    }
    function probe_path(p,    pre) {
      if (p == "*") { return "/scaffold-route-check-elsewhere" }
      if (p ~ /\*$/) { pre = substr(p, 1, length(p) - 1); return pre (pre ~ /\/$/ ? "" : "/") "scaffold-route-check" }
      return p
    }
    END {
      for (a = 1; a <= napps; a++) {
        app = order[a]
        if (!(app in hosts)) { continue }
        nh = split(hosts[app], hl, ",")
        for (h = 1; h <= nh; h++) {
          host = hl[h]; gsub(/\{\$DOMAIN\}/, domain, host); gsub(/[[:space:]]/, "", host)
          split("", asked)
          for (i = 1; i <= nl[app]; i++) {
            m = split(pats[app, i], t, " ")
            for (k = 1; k <= m; k++) {
              path = probe_path(t[k])
              if (decide(app, path) != i) { printf "skip\t%s\t%s\t%s\t%s\n", host, t[k], app, "another line of the manifest decides " path; continue }
              asked[path] = 1
              printf "%s\t%s\t%s\t%s\t%s\n", kind[app, i], host, path, app, value[app, i]
            }
          }
          for (i = 1; i <= nl[app]; i++) {
            if (kind[app, i] != "open") { continue }
            m = split(pats[app, i], t, " ")
            for (k = 1; k <= m; k++) {
              path = beside_path(t[k])
              if (path == "" || (path in asked)) { continue }
              d = decide(app, path)
              if (d == 0 || kind[app, d] != "guarded") { continue }
              asked[path] = 1
              printf "guarded\t%s\t%s\t%s\t%s\n", host, path, app, value[app, d] ", beside the open path " t[k]
            }
          }
          for (c = 1; c <= nc[app]; c++) { printf "guarded\t%s\t%s\t%s\t%s\n", host, card[app, c], app, "user (card page)" }
        }
      }
    }
  ' "$manifest"
}

failed=0; checked=0
while IFS=$'\t' read -r expect host path app what; do
  if [[ "$expect" == skip ]]; then
    echo "check-routes: skip $host $path ($app): $what"
    continue
  fi
  checked=$((checked + 1))
  result="$(curl "${curl_opts[@]}" "$scheme://$host$path" 2>/dev/null || true)"
  status="${result%%$'\t'*}"; location="${result#*$'\t'}"
  [[ "$status" =~ ^[0-9]{3}$ ]] || status=000
  to_login=0
  [[ "$status" =~ ^30[1278]$ && "$location" =~ ^https?://[^/]+/login(\?|$) ]] && to_login=1
  said="$status${location:+ -> $location}"
  if [[ "$status" == 000 ]]; then
    echo "check-routes: FAIL $host$path ($app, $what): no answer" >&2; failed=$((failed + 1))
  elif [[ "$status" =~ ^5 ]]; then
    echo "check-routes: FAIL $host$path ($app, $what): answered $said" >&2; failed=$((failed + 1))
  elif [[ "$expect" == guarded && $to_login -eq 0 ]]; then
    echo "check-routes: FAIL $host$path ($app, $what): answered $said without sign-in; expected a redirect to the gateway's /login page" >&2; failed=$((failed + 1))
  elif [[ "$expect" == open && $to_login -eq 1 ]]; then
    echo "check-routes: FAIL $host$path ($app, $what): an open path was sent to sign in ($said)" >&2; failed=$((failed + 1))
  else
    echo "check-routes: ok   $host$path ($app, $what): $said"
  fi
done < <(plan)

if [[ $failed -gt 0 ]]; then
  echo "check-routes: $failed of $checked path(s) did not answer as the manifest declares." >&2
  exit 1
fi
echo "check-routes: $checked path(s) answered as the manifest declares."
