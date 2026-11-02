#!/bin/bash
# Integration test for vps-release (docs/15-release-tree.md). Run as root in a
# throwaway Ubuntu container with network access:
#   docker run --rm -v "$PWD":/t:ro ubuntu:24.04 bash /t/test_vps_release.sh
# It deploys the public server-instance-template, whose scaffold submodule is
# recorded in SSH form, so the https normalisation is exercised as well.
set -euo pipefail
apt-get update -qq >/dev/null && apt-get install -y -qq git openssh-client ca-certificates >/dev/null
install -m 0755 /t/vps-release /usr/local/sbin/vps-release
mkdir -p /etc/vps-scaffold
: >/etc/vps-scaffold/deploy-key; chmod 600 /etc/vps-scaffold/deploy-key
: >/etc/vps-scaffold/known_hosts
printf 'REPO_URL=https://github.com/uppertoe/server-instance-template\nBRANCH=main\nKEEP=3\nVERIFY_SIGNATURE=0\n' >/etc/vps-scaffold/release.env
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "ok: $*"; }

# A legacy checkout at /opt/deploy, as on a server before adoption.
mkdir -p /opt/deploy && echo legacy >/opt/deploy/marker

tip="$(vps-release fetch)"
[[ "$tip" =~ ^[0-9a-f]{40}$ ]] || fail "fetch printed '$tip'"
ok "fetch returns the tip $tip"

rel="$(vps-release prepare)"
[[ "$rel" == "/opt/deploy-releases/$tip" ]] || fail "prepare printed '$rel'"
grep -qx "commit=$tip" "$rel/.release" || fail ".release commit"
sc="$(sed -n 's/^scaffold=//p' "$rel/.release")"
[[ "$sc" =~ ^[0-9a-f]{40}$ ]] || fail ".release scaffold '$sc'"
[[ -f "$rel/scaffold/ansible/site-quick.yml" ]] || fail "scaffold not exported"
[[ -z "$(find "$rel" ! -user root -print -quit)" ]] || fail "a file is not root-owned"
[[ -z "$(find "$rel" -type f -perm /022 -print -quit)" ]] || fail "a file is group- or world-writable"
[[ -z "$(find "$rel" -type d -perm /022 -print -quit)" ]] || fail "a directory is group- or world-writable"
x="$(find "$rel/scaffold" -name 'render-caddy-routes.sh' -print -quit)"
[[ -x "$x" ]] || fail "an executable lost its mode"
ok "prepare exports the tip and its scaffold, root-owned, no writable bits"

[[ "$(vps-release prepare)" == "$rel" ]] || fail "prepare is not idempotent"
ok "a second prepare reuses the release"

[[ "$(vps-release current)" == none ]] || fail "current before the switch"
vps-release switch "$rel"
[[ -L /opt/deploy && "$(readlink -f /opt/deploy)" == "$rel" ]] || fail "switch did not link"
[[ -f /opt/deploy-legacy/marker ]] || fail "the legacy checkout was not kept"
[[ "$(vps-release current)" == "$tip" ]] || fail "current after the switch"
ok "the first switch keeps the legacy checkout and links /opt/deploy"

# Older releases, for previous and prune.
for n in 1 2 3; do
  d="/opt/deploy-releases/old$n"; mkdir -p "$d"
  printf 'commit=old%s\nscaffold=none\nexported=2026-01-0%sT00:00:00Z\n' "$n" "$n" >"$d/.release"
done
[[ "$(vps-release previous)" == /opt/deploy-releases/old3 ]] || fail "previous is '$(vps-release previous)'"
ok "previous is the newest release that is not current"
vps-release prune
[[ -d /opt/deploy-releases/old3 && -d /opt/deploy-releases/old2 && ! -d /opt/deploy-releases/old1 ]] || fail "prune kept the wrong set"
[[ -d "$rel" ]] || fail "prune removed the current release"
ok "prune keeps three including the current one"

vps-release switch /opt/deploy-releases/old3
[[ "$(vps-release current)" == old3 ]] || fail "switch back"
ok "switching back (the rollback path) works"
vps-release switch /tmp 2>/dev/null && fail "switch accepted a non-release"
ok "switch refuses a directory that is not a prepared release"

# A symlink leaving the release is refused.
# shellcheck source=/dev/null
source /usr/local/sbin/vps-release
t="$(mktemp -d)"; ln -s /etc/shadow "$t/x"
check_links "$t" 2>/dev/null && fail "check_links accepted a link out of the release"
rm "$t/x"; mkdir -p "$t/a" "$t/c"; ln -s a "$t/b"; ln -s ../a "$t/c/d"
check_links "$t" || fail "check_links refused a link inside the release"
ln -s ../.. "$t/c/up"
check_links "$t" 2>/dev/null && fail "check_links accepted a relative link above the release"
ok "symlinks must stay inside the release"

echo "all vps-release tests passed"
