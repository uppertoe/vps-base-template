#!/usr/bin/env bash
# render-app-roles.sh -- render the app-roles manifest from the apps' Caddy
# snippets. Called by render-caddy-routes.sh, after its route lint has passed:
#
#   render-app-roles.sh <repo_root> <out_file>
#
# A site whose handles are guarded with
#
#   import role "<app>" "<role>" <upstream>
#
# is an app decided by app roles. An app that must add something to the
# request toward its upstream (a header, say) writes the route out instead,
# and the gate inside it,
#
#   import auth_gate_role "<app>" "<role>"
#
# counts as the same guard everywhere below. The gateway reads the manifest this script
# writes (APP_ROLES_FILE; the format is described in the gateway's
# internal/roles/manifest.go) to learn each app's roles, which paths need
# which role, which paths are open by design and why, and which pages a
# break-glass card may open. One TAB separates the fields:
#
#   app  role  label  hosts           a role of an app; hosts comma-separated
#   @label  app  label                the app's display name
#   @source  app  file                the snippet that declares the app
#   @path  app  patterns  role        paths that need role
#   @open  app  patterns  reason      paths open by design, and why
#   @card-page  app  path  label      a page a break-glass card may open
#
# The snippet declares what the app is with markers on comment lines just
# above the site address or inside the site block:
#
#   # scaffold-app-label: "Fellowship enquiries"
#   # scaffold-roles: admin "Administrator" editor "Editor"
#   # scaffold-card-pages: /enquiry "Your enquiry" /status "Status"
#
# The user role is always declared, with the label "User". Without an
# app-label marker the label is the app name with its first letter in
# capitals and - or _ read as a space. Paths come from the matcher of each
# top-level handle (an inline path, a one-line "@name path ..." matcher, or no
# matcher at all, which is "*"); an open handle is the one carrying the
# renderer's "# scaffold-lint: open-path -- <paths>: <reason>" marker, and the
# manifest takes its reason from the text after the colon. A handle whose
# matcher is a path_regexp takes its patterns from the marker instead, so they
# must then be exact paths or prefixes ending in "*".
#
# The render fails, with the file and line, on: a guard that names a role the
# app does not declare; one app in two site blocks (in one snippet or two); a
# site that guards with two apps; a site that mixes a role guard with the older
# guards (protected*, auth_gate and its other variants, forward_auth,
# X-Auth-Policy), which the gateway would refuse; a route block at the top level
# of the site, which Caddy runs after every handle whatever its path (import
# role at the top level is the one exception, and decides "*"); an open-path
# marker on a catch-all handle, or at the top level of the site; a card page that a user-guarded path does not decide;
# an app with role guards but none for the user role; a path the manifest
# cannot express; a path declared twice; two handles whose paths overlap
# (ignoring case) but that decide differently, because Caddy does not always
# try the more specific handle first; and a marker on a site with no role
# guard.
#
# An open handle may still ask the gateway who is signed in, so that a public
# page can greet a signed-in visitor: a reverse_proxy to the gateway's /verify,
# made only when a session cookie is present, that sends
#
#   header_up X-Auth-App "<app>"
#   header_up X-Auth-Role "<role>"
#
# and serves the page whatever the answer. Such a handle is an open path, with
# its marker and reason, and is not a guard; it sends no X-Auth-Policy, so it is
# not an older guard either. The render fails when X-Auth-App names an app
# other than the one the site guards with, when X-Auth-Role names a role the
# app does not declare, or when the site has no role guard at all.
set -euo pipefail
export LC_ALL=C

repo_root="${1:?usage: render-app-roles.sh <repo_root> <out_file>}"
out_file="${2:?usage: render-app-roles.sh <repo_root> <out_file>}"

snippets=()
if [[ -d "$repo_root/apps" ]]; then
  while IFS= read -r f; do snippets+=("$f"); done \
    < <(find "$repo_root/apps" -mindepth 2 -maxdepth 2 -type f -name '*.caddy' | sort)
fi

body="$(mktemp)"
trap 'rm -f "$body" "$out_file.tmp"' EXIT

if [[ ${#snippets[@]} -gt 0 ]]; then
  awk -v root="$repo_root/" '
    function err(file, n, msg) {
      printf "ERROR: %s:%d: %s\n", file, n, msg > "/dev/stderr"
      bad = 1
    }
    function valid_name(s) { return s ~ /^[a-z0-9_-]+$/ && length(s) <= 64 }
    # A manifest pattern: "*", an exact path, or a prefix ending in "*".
    function valid_pattern(s,    t) {
      if (s == "*") { return 1 }
      t = s; sub(/\*$/, "", t)
      return substr(s, 1, 1) == "/" && t !~ /\*/ && s !~ /[[:cntrl:][:space:]]/
    }
    # Pairs of <token> "<label>", as in the roles and card-pages markers.
    # Fills names[] and labels[], returns the count, or -1 if malformed.
    function pairs(text, names, labels,    n, m) {
      n = 0
      sub(/^[[:space:]]+/, "", text); sub(/[[:space:]]+$/, "", text)
      while (text != "") {
        if (!match(text, /^[^[:space:]"]+[[:space:]]+"[^"\t]*"/)) { return -1 }
        m = substr(text, 1, RLENGTH)
        text = substr(text, RLENGTH + 1)
        if (text != "" && text !~ /^[[:space:]]/) { return -1 }
        sub(/^[[:space:]]+/, "", text)
        n++
        names[n] = m; sub(/[[:space:]].*/, "", names[n])
        labels[n] = m; sub(/^[^"]*"/, "", labels[n]); sub(/"$/, "", labels[n])
        sub(/^[[:space:]]+/, "", labels[n]); sub(/[[:space:]]+$/, "", labels[n])
        if (labels[n] == "") { return -1 }
      }
      return n
    }
    function marker(trimmed, n,    text, k, nm, lb, cnt) {
      if (trimmed ~ /scaffold-roles:/) {
        text = trimmed; sub(/.*scaffold-roles:/, "", text)
        cnt = pairs(text, nm, lb)
        if (cnt <= 0) { err(FILENAME, n, "the marker must read: # scaffold-roles: <role> \"<Label>\" ..."); return }
        for (k = 1; k <= cnt; k++) {
          if (!valid_name(nm[k])) { err(FILENAME, n, "role \"" nm[k] "\" must be lower-case letters, digits, - or _"); continue }
          if (nm[k] == "user") { err(FILENAME, n, "the user role is always declared, with the label \"User\"; list only the other roles"); continue }
          if (nm[k] in role_label) { err(FILENAME, n, "role \"" nm[k] "\" is declared twice"); continue }
          role_label[nm[k]] = lb[k]; nroles++; role_order[nroles] = nm[k]
        }
        has_marker = 1; if (!marker_line) { marker_line = n }
      } else if (trimmed ~ /scaffold-card-pages:/) {
        text = trimmed; sub(/.*scaffold-card-pages:/, "", text)
        cnt = pairs(text, nm, lb)
        if (cnt <= 0) { err(FILENAME, n, "the marker must read: # scaffold-card-pages: <path> \"<Label>\" ..."); return }
        for (k = 1; k <= cnt; k++) { ncards++; card_path[ncards] = nm[k]; card_label[ncards] = lb[k]; card_line[ncards] = n }
        has_marker = 1; if (!marker_line) { marker_line = n }
      } else if (trimmed ~ /scaffold-app-label:/) {
        text = trimmed; sub(/.*scaffold-app-label:[[:space:]]*/, "", text); sub(/[[:space:]]+$/, "", text)
        if (text !~ /^"[^"\t]+"$/) { err(FILENAME, n, "the marker must read: # scaffold-app-label: \"<Label>\""); return }
        if (app_label != "") { err(FILENAME, n, "the app label is declared twice"); return }
        app_label = substr(text, 2, length(text) - 2)
        has_marker = 1; if (!marker_line) { marker_line = n }
      }
    }
    function is_app_marker(t) { return t ~ /scaffold-(roles|card-pages|app-label):/ }
    function reset_site(    k) {
      split("", role_label); split("", role_order); nroles = 0
      split("", card_path); split("", card_label); split("", card_line); ncards = 0
      split("", mkind); split("", mpats)
      split("", h_line); split("", h_spec); split("", h_open); split("", h_reason); split("", h_mpaths)
      split("", h_app); split("", h_role); split("", h_guard_line); nh = 0
      split("", ask_kind); split("", ask_value); split("", ask_line); nask = 0
      app_label = ""; has_marker = 0; marker_line = 0
      top_app = ""; top_role = ""; top_line = 0; top_open_line = 0; route_line = 0
      old_line = 0; cur = 0; in_errors = 0; pending_open = 0
    }
    # The guard line: import role "<app>" "<role>" <upstream>, or the gate
    # written out in a route, import auth_gate_role "<app>" "<role>". Sets
    # g_app and g_role, or reports the malformed line.
    function guard(trimmed, n,    p, k) {
      k = split(trimmed, p, "\"")
      if (trimmed ~ /^import auth_gate_role/) {
        if (k != 5 || p[1] !~ /^import auth_gate_role[[:space:]]+$/ || p[3] !~ /^[[:space:]]+$/ || p[5] != "") {
          err(FILENAME, n, "the gate must read import auth_gate_role \"<app>\" \"<role>\"")
          return 0
        }
      } else if (k < 5 || p[1] !~ /^import role[[:space:]]+$/ || p[3] !~ /^[[:space:]]+$/ || p[5] !~ /^[[:space:]]+[^[:space:]]/) {
        err(FILENAME, n, "the guard must read import role \"<app>\" \"<role>\" <upstream>")
        return 0
      }
      g_app = p[2]; g_role = p[4]
      if (!valid_name(g_app) || !valid_name(g_role)) {
        err(FILENAME, n, "app \"" g_app "\" and role \"" g_role "\" must be lower-case letters, digits, - or _")
        return 0
      }
      return 1
    }
    # The patterns a handle answers, from its matcher; "" with an error
    # reported when the manifest cannot say.
    function patterns(i,    spec, name, out, k, n, t) {
      spec = h_spec[i]
      if (spec == "" || spec == "*") { return "*" }
      if (substr(spec, 1, 1) == "@") {
        name = spec
        if (!(name in mkind)) {
          err(FILENAME, h_line[i], "matcher " name " is not defined on one line in this site, so the manifest cannot say which paths this handle answers; define it here as \"" name " path ...\"")
          return ""
        }
        if (mkind[name] == "path") {
          spec = mpats[name]
        } else if (mkind[name] == "path_regexp" && h_open[i]) {
          spec = h_mpaths[i]
          if (spec == "") { err(FILENAME, h_line[i], "the open-path marker must list the paths this " name " matcher answers"); return "" }
        } else {
          err(FILENAME, h_line[i], "in a site guarded by app roles, a handle needs a path matcher (or, on an open path, a path_regexp whose marker lists the paths), so the manifest can say which paths it answers; " name " is a " mkind[name] " matcher")
          return ""
        }
      }
      n = split(spec, t, /[[:space:]]+/); out = ""
      for (k = 1; k <= n; k++) {
        if (t[k] == "") { continue }
        if (!valid_pattern(t[k])) {
          err(FILENAME, h_line[i], "path \"" t[k] "\" cannot be written in the app-roles manifest: use an exact path, or a prefix ending in *")
          return ""
        }
        out = out (out == "" ? "" : " ") t[k]
      }
      return out
    }
    # The decision the gateway makes (roles.App.Decide): an exact pattern
    # first, then the longest prefix, then "*". Returns the line index.
    function decide(path,    i, k, n, t, s, best, score, pre) {
      best = 0; score = -1
      for (i = 1; i <= nl; i++) {
        n = split(l_pats[i], t, " ")
        for (k = 1; k <= n; k++) {
          s = -1
          if (t[k] == "*") { s = 0 }
          else if (t[k] ~ /\*$/) { pre = substr(t[k], 1, length(t[k]) - 1); if (substr(path, 1, length(pre)) == pre) { s = 1 + length(pre) } }
          else if (t[k] == path) { s = 1048576 }
          if (s > score) { score = s; best = i }
        }
      }
      return best
    }
    function add_line(kind, pats, value, n,    k, t, m) {
      m = split(pats, t, " ")
      for (k = 1; k <= m; k++) {
        if (t[k] in pat_line) { err(FILENAME, n, "path " t[k] " is already decided at line " pat_line[t[k]]); return }
      }
      for (k = 1; k <= m; k++) { pat_line[t[k]] = n }
      nl++; l_kind[nl] = kind; l_pats[nl] = pats; l_value[nl] = value; l_line[nl] = n
    }
    # Whether Caddy could match one path against both patterns. The Caddy path
    # matcher ignores case, so the comparison does too; "*" is the catch-all,
    # which Caddy always tries last.
    function overlap(a, b,    pa, pb) {
      if (a == "*" || b == "*") { return 0 }
      a = tolower(a); b = tolower(b)
      pa = (a ~ /\*$/) ? substr(a, 1, length(a) - 1) : ""
      pb = (b ~ /\*$/) ? substr(b, 1, length(b) - 1) : ""
      if (pa == "" && pb == "") { return a == b }
      if (pa == "") { return substr(a, 1, length(pb)) == pb }
      if (pb == "") { return substr(b, 1, length(pa)) == pa }
      return substr(pa, 1, length(pb)) == pb || substr(pb, 1, length(pa)) == pa
    }
    function decision(i) { return l_kind[i] == "@open" ? "open" : "the " l_value[i] " role" }
    function finish_site(    i, j, m, q, u, app, guarded, has_user, pats, buf, hosts, k, n, t, d, label) {
      app = ""; guarded = 0; has_user = 0
      if (top_app != "") { app = top_app; guarded = 1 }
      for (i = 1; i <= nh; i++) {
        if (h_app[i] == "") { continue }
        guarded = 1
        if (app == "") { app = h_app[i] }
        else if (h_app[i] != app) { err(FILENAME, h_guard_line[i], "site " site_addr " guards with two apps, \"" app "\" and \"" h_app[i] "\"; one site block is one app") }
      }
      if (!guarded) {
        if (has_marker) { err(FILENAME, marker_line, "site " site_addr " carries an app-roles marker but has no import role guard") }
        if (nask) { err(FILENAME, ask_line[1], "site " site_addr " sends " ask_kind[1] " to the gateway but has no import role guard") }
        return
      }
      if (route_line) {
        err(FILENAME, route_line, "in site " site_addr ", which is guarded by app roles, a route block at the top level runs after every handle whatever its path, so the manifest cannot say which paths it decides; write it as a handle with the same matcher (a route inside a handle is fine)")
      }
      if (old_line) {
        err(FILENAME, old_line, "site " site_addr " mixes import role with an older guard (protected, auth_gate, forward_auth or X-Auth-Policy); the gateway refuses a request that carries both, so migrate the whole site to role guards")
      }
      if (app in app_file) {
        err(FILENAME, site_line, "app \"" app "\" is already declared by the site at " app_file[app] ":" app_line[app] "; one app is one site block (list several addresses on it to serve more hosts)")
        return
      }
      app_file[app] = FILENAME; app_line[app] = site_line
      # The roles each guard names must be declared.
      if (top_app != "") {
        if (top_role == "user") { has_user = 1 }
        else if (!(top_role in role_label)) { err(FILENAME, top_line, "role \"" top_role "\" is not declared for app \"" app "\": declare it above the site with # scaffold-roles: " top_role " \"<Label>\"") }
      }
      for (i = 1; i <= nh; i++) {
        if (h_app[i] == "") { continue }
        if (h_role[i] == "user") { has_user = 1 }
        else if (!(h_role[i] in role_label)) { err(FILENAME, h_guard_line[i], "role \"" h_role[i] "\" is not declared for app \"" app "\": declare it above the site with # scaffold-roles: " h_role[i] " \"<Label>\"") }
      }
      # A cookie-optional verify on an open path asks about this app, and
      # about a role it declares.
      for (k = 1; k <= nask; k++) {
        if (ask_kind[k] == "X-Auth-App" && ask_value[k] != app) { err(FILENAME, ask_line[k], "X-Auth-App names app \"" ask_value[k] "\", but site " site_addr " is app \"" app "\"") }
        if (ask_kind[k] == "X-Auth-Role" && ask_value[k] != "user" && !(ask_value[k] in role_label)) { err(FILENAME, ask_line[k], "X-Auth-Role names role \"" ask_value[k] "\", which app \"" app "\" does not declare") }
      }
      if (!has_user) {
        err(FILENAME, site_line, "app \"" app "\" has role guards but none for the user role: guard the paths every signed-in user may open with import role \"" app "\" \"user\" <upstream>")
      }
      if (top_open_line) {
        err(FILENAME, top_open_line, "an open-path marker at the top level of site " site_addr " would open every path of app \"" app "\" that no handle names; give the open paths their own handle and matcher")
      }
      # The path lines, in the order of the handles.
      split("", pat_line); split("", l_kind); split("", l_pats); split("", l_value); split("", l_line); nl = 0
      for (i = 1; i <= nh; i++) {
        if (h_app[i] != "" && h_open[i]) {
          err(FILENAME, h_line[i], "this handle carries both a role guard and an open-path marker; a path is either guarded or open")
          continue
        }
        if (h_open[i] && (h_spec[i] == "" || h_spec[i] == "*")) {
          err(FILENAME, h_line[i], "an open-path marker on a catch-all handle would open every path of app \"" app "\" that no other handle names; give the open paths their own matcher")
          continue
        }
        if (h_app[i] == "" && !h_open[i]) { continue }
        pats = patterns(i)
        if (pats == "") { continue }
        if (h_open[i]) { add_line("@open", pats, h_reason[i], h_line[i]) }
        else { add_line("@path", pats, h_role[i], h_guard_line[i]) }
      }
      if (top_app != "") { add_line("@path", "*", top_role, top_line) }
      # Caddy does not always try the more specific of two handles first: it
      # sorts handles by path length only when both have a single path, and
      # keeps the written order otherwise, so the manifest cannot know which
      # of two overlapping handles Caddy picks. Overlapping handles must
      # therefore decide the same way.
      for (i = 1; i <= nl; i++) {
        n = split(l_pats[i], t, " ")
        for (j = i + 1; j <= nl; j++) {
          if (decision(i) == decision(j)) { continue }
          m = split(l_pats[j], u, " ")
          for (k = 1; k <= n; k++) {
            for (q = 1; q <= m; q++) {
              if (overlap(t[k], u[q])) {
                err(FILENAME, l_line[j], "path " u[q] " overlaps " t[k] " at line " l_line[i] ", and the two handles decide differently (" decision(j) " here, " decision(i) " there); Caddy does not always try the more specific handle first, so in a site guarded by app roles two handles whose paths overlap must decide the same way: move one path out from under the other, or give both handles the same guard")
                k = n; q = m
              }
            }
          }
        }
      }
      # Card pages: exact paths that a user-guarded line decides.
      for (k = 1; k <= ncards; k++) {
        if (!valid_pattern(card_path[k]) || card_path[k] ~ /\*/) {
          err(FILENAME, card_line[k], "card page \"" card_path[k] "\" must be an exact path")
          continue
        }
        for (i = 1; i < k; i++) { if (card_path[i] == card_path[k]) { err(FILENAME, card_line[k], "card page " card_path[k] " is declared twice") } }
        d = decide(card_path[k])
        if (d == 0 || l_kind[d] != "@path" || l_value[d] != "user") {
          err(FILENAME, card_line[k], "card page " card_path[k] " is not under a path guarded by import role \"" app "\" \"user\"; a break-glass card holds only the user role" (d == 0 ? "" : (l_kind[d] == "@open" ? " (an open path decides it)" : " (the " l_value[d] " role decides it)")))
        }
      }
      # The records.
      hosts = site_addr
      label = app_label
      if (label == "") { label = app; gsub(/[-_]/, " ", label); label = toupper(substr(label, 1, 1)) substr(label, 2) }
      buf = app "\tuser\tUser\t" hosts "\n"
      for (k = 1; k <= nroles; k++) { buf = buf app "\t" role_order[k] "\t" role_label[role_order[k]] "\t" hosts "\n" }
      src = FILENAME; if (index(src, root) == 1) { src = substr(src, length(root) + 1) }
      buf = buf "@label\t" app "\t" label "\n@source\t" app "\t" src "\n"
      for (i = 1; i <= nl; i++) { buf = buf l_kind[i] "\t" app "\t" l_pats[i] "\t" l_value[i] "\n" }
      for (k = 1; k <= ncards; k++) { buf = buf "@card-page\t" app "\t" card_path[k] "\t" card_label[k] "\n" }
      napps++; out[napps] = buf
    }
    # Markers left over after the last site of a file belong to no site.
    function flush_pending(    k) {
      for (k = 1; k <= pend_n; k++) { err(pend_file, pend_line[k], "an app-roles marker belongs just above a site address or inside its block") }
      pend_n = 0
    }
    FNR == 1 {
      flush_pending()
      depth = 0; in_site = 0; split("", pend_text); split("", pend_line)
    }
    {
      line = $0
      trimmed = line; sub(/^[[:space:]]*/, "", trimmed); sub(/[[:space:]]+$/, "", trimmed)
      comment = (substr(trimmed, 1, 1) == "#")
      opens = comment ? 0 : gsub(/\{/, "{", line)
      closes = comment ? 0 : gsub(/\}/, "}", line)

      if (depth == 0) {
        if (comment) {
          if (is_app_marker(trimmed)) { pend_n++; pend_text[pend_n] = trimmed; pend_line[pend_n] = FNR; pend_file = FILENAME }
        } else if (trimmed != "") {
          if (line ~ /\{[[:space:]]*$/ && substr(trimmed, 1, 1) != "(") {
            in_site = 1; site_line = FNR
            site_addr = trimmed; sub(/[[:space:]]*\{$/, "", site_addr)
            gsub(/[[:space:]]*,[[:space:]]*/, ",", site_addr)
            na = split(site_addr, addrs, ","); site_addr = ""
            for (k = 1; k <= na; k++) { sub(/^https?:\/\//, "", addrs[k]); site_addr = site_addr (k > 1 ? "," : "") addrs[k] }
            reset_site()
            for (k = 1; k <= pend_n; k++) { marker(pend_text[k], pend_line[k]) }
          } else {
            flush_pending()
          }
          pend_n = 0
        }
      } else if (in_site) {
        if (comment) {
          if (is_app_marker(trimmed)) { marker(trimmed, FNR) }
          if (trimmed ~ /scaffold-lint: open-path/ && !in_errors) {
            mt = trimmed; sub(/.*scaffold-lint: open-path[[:space:]]*(--)?[[:space:]]*/, "", mt)
            mpaths = mt; sub(/:.*/, "", mpaths); sub(/^[[:space:]]+/, "", mpaths); sub(/[[:space:]]+$/, "", mpaths)
            reason = mt; sub(/^[^:]*:[[:space:]]*/, "", reason); gsub(/\t/, " ", reason)
            if (cur) { h_open[cur] = 1; h_reason[cur] = reason; h_mpaths[cur] = mpaths }
            else { pending_open = FNR; p_reason = reason; p_mpaths = mpaths }
          }
        } else if (trimmed != "") {
          if ((trimmed ~ /^import (protected|auth_gate)/ && trimmed !~ /^import auth_gate_role([[:space:]]|$)/) || trimmed ~ /^forward_auth([[:space:]]|\{|$)/ || trimmed ~ /^header_up X-Auth-Policy[[:space:]]/) {
            if (!old_line) { old_line = FNR }
          }
          # header_up X-Auth-App "<app>" or X-Auth-Role "<role>": a
          # cookie-optional verify, checked when the site closes.
          if (trimmed ~ /^header_up X-Auth-(App|Role)[[:space:]]/) {
            nask++; ask_line[nask] = FNR
            ask_kind[nask] = trimmed; sub(/^header_up[[:space:]]+/, "", ask_kind[nask]); sub(/[[:space:]].*/, "", ask_kind[nask])
            ask_value[nask] = trimmed; sub(/^header_up[[:space:]]+[^[:space:]]+[[:space:]]+/, "", ask_value[nask]); gsub(/"/, "", ask_value[nask])
          }
          if (depth == 1) {
            if (substr(trimmed, 1, 1) == "@") {
              mname = trimmed; sub(/[[:space:]].*/, "", mname)
              rest = trimmed; sub(/^@[^[:space:]]+[[:space:]]*/, "", rest)
              if (rest ~ /^\{/ ) { mkind[mname] = "block" }
              else if (rest ~ /^path[[:space:]]/) { mkind[mname] = "path"; mpats[mname] = rest; sub(/^path[[:space:]]+/, "", mpats[mname]) }
              else { k2 = rest; sub(/[[:space:]].*/, "", k2); mkind[mname] = k2 }
            } else if (trimmed ~ /^handle_errors([[:space:]]|\{)/ && line ~ /\{[[:space:]]*$/) {
              in_errors = 1; pending_open = 0
            } else if (trimmed ~ /^(handle|handle_path|route)([[:space:]]|\{)/ && line ~ /\{[[:space:]]*$/) {
              nh++; cur = nh; h_line[nh] = FNR
              if (trimmed ~ /^route/ && !route_line) { route_line = FNR }
              spec = trimmed; sub(/^[a-z_]+[[:space:]]*/, "", spec); sub(/[[:space:]]*\{$/, "", spec)
              h_spec[nh] = spec; h_app[nh] = ""
              if (pending_open) { h_open[nh] = 1; h_reason[nh] = p_reason; h_mpaths[nh] = p_mpaths; pending_open = 0 }
            } else if (trimmed ~ /^import (role|auth_gate_role)([[:space:]]|$)/) {
              if (guard(trimmed, FNR)) {
                if (top_app != "") { err(FILENAME, FNR, "a second role guard at the top level of the site") }
                else { top_app = g_app; top_role = g_role; top_line = FNR }
              }
              pending_open = 0
            } else {
              if (pending_open) { top_open_line = pending_open; pending_open = 0 }
            }
          } else if (cur && !in_errors && trimmed ~ /^import (role|auth_gate_role)([[:space:]]|$)/) {
            if (guard(trimmed, FNR)) {
              if (h_app[cur] != "") { err(FILENAME, FNR, "a second role guard in one handle; give each role its own handle") }
              else { h_app[cur] = g_app; h_role[cur] = g_role; h_guard_line[cur] = FNR }
            }
          }
        }
      }

      depth += opens - closes
      if (in_site && depth <= 1) { cur = 0; in_errors = 0 }
      if (in_site && depth == 0 && FNR != site_line) {
        finish_site(); in_site = 0
      }
    }
    END {
      flush_pending()
      if (bad) { exit 1 }
      for (i = 1; i <= napps; i++) { printf "%s%s", (i > 1 ? "\n" : ""), out[i] }
    }
  ' "${snippets[@]}" > "$body"
fi

{
  printf '# Generated by scaffold/docker/render-app-roles.sh; do not edit.\n'
  printf '# The app-roles manifest (APP_ROLES_FILE): each app'\''s roles, the paths that\n'
  printf '# need each role, the paths open by design and the pages a break-glass card\n'
  printf '# may open. Fields are separated by one TAB; the gateway'\''s\n'
  printf '# internal/roles/manifest.go describes the format.\n'
  if [[ -s "$body" ]]; then printf '\n'; cat "$body"; fi
} > "$out_file.tmp"
mv "$out_file.tmp" "$out_file"
