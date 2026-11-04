#!/bin/bash
# Integration test for vps-release (docs/15-release-tree.md). Run as root in a
# throwaway Ubuntu container with network access:
#   docker run --rm -v "$PWD":/t:ro ubuntu:24.04 bash /t/test_vps_release.sh
# It deploys the public server-instance-template, whose scaffold submodule is
# recorded in SSH form, so the https normalisation is exercised as well.
set -euo pipefail
apt-get update -qq >/dev/null && apt-get install -y -qq git openssh-client ca-certificates util-linux >/dev/null
install -m 0755 /t/vps-release /usr/local/sbin/vps-release
# The template carries a secrets/ directory, so every prepare runs the secrets
# render step; stand in for the renderer before the first one. The stub records
# its arguments for the checks further down.
cat >/usr/local/sbin/vps-secrets-render <<'R'
#!/bin/sh
echo "$@" >/tmp/render-args
echo "vps-secrets-render: .env written"
R
chmod 0755 /usr/local/sbin/vps-secrets-render
# The bind check needs docker; with no containers it has nothing to refuse.
printf '#!/bin/sh\nexit 0\n' >/usr/local/sbin/vps-release-bind-check; chmod 0755 /usr/local/sbin/vps-release-bind-check
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
ok "fetch returns the tip"
[[ "$(git --git-dir=/var/lib/vps-deploy/repo.git rev-parse HEAD)" == "$tip" ]] || fail "the mirror's HEAD is not the fetched tip"
ok "the mirror's HEAD names the fetched branch"

# A failed fetch fails, rather than falling back to the cached tip.
cp /etc/vps-scaffold/release.env /tmp/release.env
sed -i 's#^REPO_URL=.*#REPO_URL=https://github.com/uppertoe/does-not-exist-xyz#' /etc/vps-scaffold/release.env
if out="$(vps-release prepare 2>/dev/null)"; then fail "prepare succeeded on a failed fetch ($out)"; fi
cp /tmp/release.env /etc/vps-scaffold/release.env
ok "a failed fetch fails prepare"

rel="$(vps-release prepare)"
[[ "$rel" == "/opt/deploy-releases/$tip" ]] || fail "prepare printed '$rel'"
grep -qx "commit=$tip" "$rel/.release" || fail ".release commit"
sc="$(sed -n 's/^scaffold=//p' "$rel/.release")"
[[ "$sc" =~ ^[0-9a-f]{40}$ ]] || fail ".release scaffold '$sc'"
[[ -f "$rel/scaffold/ansible/site-quick.yml" ]] || fail "scaffold not exported"
[[ -z "$(find "$rel" ! -user root -print -quit)" ]] || fail "a file is not root-owned"
[[ -z "$(find "$rel" -perm /022 ! -type l -print -quit)" ]] || fail "something is group- or world-writable"
x="$(find "$rel/scaffold" -name 'render-caddy-routes.sh' -print -quit)"
[[ -x "$x" ]] || fail "an executable lost its mode"
ok "prepare exports the tip and its scaffold, root-owned, no writable bits"
[[ "$(vps-release prepare)" == "$rel" ]] || fail "prepare is not idempotent"
ok "a second prepare reuses the release"

# The secrets render step's progress lines must not reach prepare's stdout.
rm -rf "$rel"
# Give this export a secrets/ directory: check_links runs on the partial tree
# just before the render step, so a test override of it can add one.
# shellcheck source=/dev/null
source /usr/local/sbin/vps-release
# shellcheck disable=SC2317,SC2329  # do_prepare calls this override
out="$( check_links() { mkdir -p "$1/secrets"; }; do_prepare )"
[[ "$out" == "$rel" ]] || fail "prepare's stdout carried render output: '$out'"
grep -q -- '--restic-dir /etc/restic' /tmp/render-args || fail "prepare did not ask the renderer to install the backup set into /etc/restic (got: $(cat /tmp/render-args))"
ok "the render step installs the backup set into /etc/restic"
# A render failure fails prepare and leaves no partial release behind.
printf '#!/bin/sh\necho "vps-secrets-render: refused" >&2\nexit 1\n' >/usr/local/sbin/vps-secrets-render
rm -rf "$rel"
# shellcheck disable=SC2317,SC2329  # do_prepare calls this override
if out="$( check_links() { mkdir -p "$1/secrets"; }; do_prepare 2>/dev/null )"; then fail "prepare succeeded although the render step failed ($out)"; fi
[[ -z "$(ls -d /opt/deploy-releases/.*.partial 2>/dev/null)" ]] || fail "a partial release survived a failed render"
ok "a failed render fails prepare and removes the partial release"
cat >/usr/local/sbin/vps-secrets-render <<'R'
#!/bin/sh
echo "$@" >/tmp/render-args
echo "vps-secrets-render: .env written"
R
chmod 0755 /usr/local/sbin/vps-secrets-render
# Put the release back for the steps below.
[[ "$(vps-release prepare)" == "$rel" ]] || fail "prepare did not recreate the release after the failed render"
ok "the render step's output stays off prepare's stdout"

[[ "$(vps-release current)" == none ]] || fail "current before the switch"

# The first switch refuses env files the release would lose.
mkdir -p /opt/deploy/apps/x && echo A=1 >/opt/deploy/apps/x/.env
vps-release switch "$rel" 2>/dev/null && fail "switch accepted a checkout env file missing from the release"
rm -rf /opt/deploy/apps
ok "the first switch refuses env files missing from the release"

vps-release switch "$rel"
[[ -L /opt/deploy && "$(readlink -f /opt/deploy)" == "$rel" ]] || fail "switch did not link"
[[ -f /opt/deploy-legacy/marker ]] || fail "the legacy checkout was not kept"
[[ "$(vps-release current)" == "$tip" ]] || fail "current after the switch"
ok "the first switch keeps the legacy checkout and links /opt/deploy"

# The manifest: root-only, and verify finds a change, an addition and a
# removal in the live release, then passes once the tree is restored.
[[ "$(stat -c '%a %U' "$rel/.manifest")" == "600 root" ]] || fail "the manifest is not root-only"
vps-release verify >/dev/null || fail "verify failed on an untouched release"
f="$(cd "$rel" && find . -type f -name '*.md' ! -path './.*' | head -1)"
cp "$rel/$f" /tmp/orig
echo tampered >>"$rel/$f"
out="$(vps-release verify 2>&1)" && fail "verify passed a changed file"
grep -q "changed: $f" <<<"$out" || fail "verify did not name the changed file: $out"
cp /tmp/orig "$rel/$f"
touch "$rel/planted"
out="$(vps-release verify 2>&1)" && fail "verify passed an added file"
grep -q 'added: ./planted' <<<"$out" || fail "verify did not name the added file: $out"
rm "$rel/planted"
chmod 0755 "$rel/$f"
vps-release verify >/dev/null 2>&1 && fail "verify passed a changed mode"
chmod 0644 "$rel/$f"
vps-release verify >/dev/null || fail "verify failed after the tree was restored"
ok "the manifest is root-only, and verify finds changed, added and re-moded files"

# Three more releases, deployed in order A B C after the tip, by switching.
mk() { local d="/opt/deploy-releases/$1"; mkdir -p "$d"; printf 'commit=%s\nscaffold=none\nexported=2020-01-01T00:00:00Z\n' "$1" >"$d/.release"; echo "$d"; }
A=$(mk "$(printf 'a%.0s' {1..40})"); B=$(mk "$(printf 'b%.0s' {1..40})"); C=$(mk "$(printf 'c%.0s' {1..40})")
vps-release switch "$A"; vps-release switch "$B"; vps-release switch "$A"; vps-release switch "$C"
[[ "$(vps-release previous)" == "$A" ]] || fail "previous after A B A C is '$(vps-release previous)', expected A"
ok "previous follows the switch history, not export times"
# A release a running container still mounts survives prune.
line="3550 3540 253:1 /opt/deploy-releases/${rel##*/}/apps/www /srv rw,relatime - ext4 /dev/vda1 rw"
[[ "$(releases_in_mountinfo <<<"$line")" == "$rel" ]] || fail "mountinfo parsing missed the release"
# shellcheck disable=SC2317,SC2329  # do_prune calls this override
( mounted_releases() { echo "$rel"; }; do_prune )
[[ -d "$rel" ]] || fail "prune removed a release a container still mounts"
ok "prune keeps a release that a running container still mounts"
vps-release prune
[[ -d "$C" && -d "$A" && -d "$B" && ! -d "$rel" ]] || fail "prune kept the wrong set"
ok "prune keeps the current release and the two most recently deployed"
vps-release switch /tmp 2>/dev/null && fail "switch accepted a non-release"
ok "switch refuses a directory that is not a prepared release"

vps-release hold "$tip"; [[ "$(vps-release held)" == "$tip" ]] || fail "hold"
vps-release unhold; [[ -z "$(vps-release held)" ]] || fail "unhold"
ok "hold and unhold"

# Two runs are serialised by the lock.
( exec 8>/run/vps-release.lock; flock 8; sleep 3 ) &
sleep 0.5; t0=$(date +%s); vps-release current >/dev/null; t1=$(date +%s); wait
(( t1 - t0 >= 2 )) || fail "a second run did not wait for the lock"
ok "runs are serialised by the lock"

t="$(mktemp -d)"; ln -s /etc/shadow "$t/x"
check_links "$t" 2>/dev/null && fail "check_links accepted a link out of the release"
rm "$t/x"; mkdir -p "$t/a" "$t/c"; ln -s a "$t/b"; ln -s ../a "$t/c/d"
check_links "$t" || fail "check_links refused a link inside the release"
ln -s ../.. "$t/c/up"
check_links "$t" 2>/dev/null && fail "check_links accepted a relative link above the release"
ok "symlinks must stay inside the release"
normalise_scaffold_url git@github.com:o/r.git | grep -qx https://github.com/o/r.git || fail "ssh form"
normalise_scaffold_url https://evil.example/o/r 2>/dev/null && fail "accepted a non-GitHub URL"
ok "scaffold URLs are normalised to https://github.com and others refused"

echo "all vps-release tests passed"
