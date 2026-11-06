#!/bin/bash
# Test of the checkout-mode vps-deploy wrapper's refusals (docs/05). Run as
# root in a throwaway Ubuntu container, with the role directory mounted:
#   docker run --rm -v "$PWD/ansible/roles/deploy-user":/t:ro ubuntu:24.04 \
#     bash /t/files/test_vps_deploy.sh
# The template is rendered here with python3-jinja2 for a checkout-mode,
# unsigned server; docker, the renderer, the notifier and the heal helper are
# stubs that record what they were asked to do. Each scenario sets up a
# condition the 2026-11-03 review showed could steer root, then checks that
# the wrapper refuses it, and that a clean deploy still reaches compose.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq git python3-jinja2 util-linux >/dev/null
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "ok: $*"; }

useradd -m -s /bin/bash deploy
git config --global init.defaultBranch main
git config --global user.email t@example.org; git config --global user.name t
git config --global protocol.file.allow always
git config --system protocol.file.allow always
# The origin and the scaffold source are root-owned and read by the deploy
# account; the checks under test pass safe.directory explicitly themselves.
git config --system --add safe.directory '*'

# Stubs. docker records its arguments; compose config prints no services.
mkdir -p /usr/local/sbin /usr/local/bin /var/lib/vps-deploy /run
cat >/usr/local/bin/docker <<'EOF'
#!/bin/sh
echo "docker $*" >>/tmp/docker.log
# compose config --images reads images.txt from the release, so a test commit
# can change an image.
if [ "$1 $2 $3" = "compose config --images" ]; then cat images.txt 2>/dev/null || echo app:1; exit 0; fi
if [ "$1 $2" = "compose config" ]; then echo '{"services":{}}'; fi
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' >/usr/local/sbin/vps-git-heal
printf '#!/bin/sh\nexit 0\n' >/usr/local/sbin/vps-secrets-render
# The acceptance probes record their call, with the outcome sentence and the
# notifier the caller gave them, and fail when /tmp/probes-fail exists: an
# empty file fails every run, a file holding a commit fails only the run
# against the release of that commit (so a rollback's probes can pass). The
# failing host is written to the caller's file when one is named.
cat >/usr/local/sbin/vps-deploy-probes <<'EOF'
#!/bin/bash
echo "probes $1 notify=${VPS_DEPLOY_PROBES_NOTIFY-unset} outcome=${VPS_DEPLOY_PROBES_OUTCOME:-}" >>/tmp/docker.log
[[ -e /tmp/probes-fail ]] || exit 0
if [[ -s /tmp/probes-fail ]]; then
  commit="$(sed -n 's/^commit=//p' "$1/.release" 2>/dev/null)"
  [[ "$commit" == "$(cat /tmp/probes-fail)" ]] || exit 0
fi
[[ -n "${VPS_DEPLOY_PROBES_FAILED_FILE:-}" ]] && echo "app.example.org" >"$VPS_DEPLOY_PROBES_FAILED_FILE"
exit 1
EOF
# shellcheck disable=SC2016  # the $1 and $2 are for the stub, not this shell
printf '#!/bin/sh\necho "notify: $1" >>/tmp/notify.log\necho "$2" >>/tmp/notify.log\nexit 0\n' >/usr/local/bin/vps-notify
# systemctl: nothing is active, so the apt wait returns at once.
printf '#!/bin/sh\necho inactive\n' >/usr/local/bin/systemctl
chmod 0755 /usr/local/bin/docker /usr/local/sbin/vps-git-heal /usr/local/sbin/vps-secrets-render /usr/local/sbin/vps-deploy-probes /usr/local/bin/vps-notify /usr/local/bin/systemctl

# Render the wrapper: checkout mode, no signature gate (the gate is covered by
# the Molecule suite and needs a trust store), branch main.
python3 - <<'PY'
import jinja2
env = jinja2.Environment()
env.filters["bool"] = lambda v: v if isinstance(v, bool) else str(v).lower() in ("true", "1", "yes")
src = open("/t/templates/vps-deploy.j2").read()
out = env.from_string(src).render(deploy_release_tree=False, deploy_verify_signature=False, deploy_user="deploy", deploy_branch="main")
open("/usr/local/sbin/vps-deploy", "w").write(out)
PY
chmod 0750 /usr/local/sbin/vps-deploy

# A bare origin with one app, a hook and a scaffold submodule, and the
# deploy-owned checkout at /opt/deploy tracking it.
mkdir -p /srv/scaffold-src/docker && (cd /srv/scaffold-src && git init -q && echo base >docker/caddy.base.yml && git add . && git commit -qm scaffold)
git init -q --bare /srv/origin.git
mkdir -p /srv/work && cd /srv/work && git init -q && mkdir -p apps/x
printf 'services: {}\n' >docker-compose.yml
printf '#!/bin/bash\necho hook-ran >>/tmp/hook.log\n' >apps/x/deploy.sh && chmod +x apps/x/deploy.sh
git submodule add -q /srv/scaffold-src scaffold
git add . && git commit -qm "first" && git remote add origin /srv/origin.git && git push -q origin main
cd /
fresh_checkout() {
  rm -rf /opt/deploy
  install -d -o deploy -g deploy -m 0755 /opt/deploy
  runuser -u deploy -- git clone -q --recurse-submodules /srv/origin.git /opt/deploy
}
fresh_checkout
run() { : >/tmp/docker.log; : >/tmp/hook.log; /usr/local/sbin/vps-deploy "$@"; }
reset_checkout() { rm -f /var/lib/vps-deploy/last-deployed; fresh_checkout; }

# 1. A clean checkout deploys: compose is called and the hook runs.
run >/tmp/out.log 2>&1 || fail "clean deploy refused: $(cat /tmp/out.log)"
grep -q 'docker compose up -d --remove-orphans --wait' /tmp/docker.log || fail "compose up not called"
grep -q hook-ran /tmp/hook.log || fail "hook did not run"
[[ "$(cat /var/lib/vps-deploy/last-deployed)" == "$(git -C /opt/deploy rev-parse HEAD)" ]] || fail "last-deployed not recorded"
# The probes run after compose up, against the stack directory.
grep -A99 'docker compose up' /tmp/docker.log | grep -q '^probes /opt/deploy ' || fail "the acceptance probes did not run after compose up: $(cat /tmp/docker.log)"
ok "a clean checkout deploys, is probed and is recorded"

# 2. core.worktree pointing at a clean copy must not hide an edited hook.
cp -a /opt/deploy /srv/decoy && chown -R deploy:deploy /srv/decoy
runuser -u deploy -- git -C /opt/deploy config core.worktree /srv/decoy
echo 'echo EVIL' >>/opt/deploy/apps/x/deploy.sh
if run >/tmp/out.log 2>&1; then fail "deploy proceeded with core.worktree set and an edited hook"; fi
grep -q 'core.worktree' /tmp/out.log || fail "refusal did not name core.worktree: $(cat /tmp/out.log)"
[[ ! -s /tmp/docker.log ]] || fail "docker was called"
ok "core.worktree in the deploy-owned config is refused"
reset_checkout

# 3. A clean filter from the deploy-owned config must never run as root.
runuser -u deploy -- git -C /opt/deploy config filter.x.clean "sh -c 'touch /tmp/FILTER_RAN; cat'"
runuser -u deploy -- sh -c 'echo "* filter=x" >/opt/deploy/.git/info/attributes'
runuser -u deploy -- touch /opt/deploy/docker-compose.yml
if run >/tmp/out.log 2>&1; then fail "deploy proceeded with a clean filter configured"; fi
[[ ! -e /tmp/FILTER_RAN ]] || fail "the filter ran as root"
grep -q 'filter.x.clean' /tmp/out.log || fail "refusal did not name the filter: $(cat /tmp/out.log)"
ok "a clean filter in the deploy-owned config is refused before any index refresh"
reset_checkout

# 4. An attributes file under .git is refused even without a filter key.
runuser -u deploy -- sh -c 'echo "* text" >/opt/deploy/.git/info/attributes'
if run >/tmp/out.log 2>&1; then fail "deploy proceeded with .git/info/attributes present"; fi
grep -q 'info/attributes' /tmp/out.log || fail "refusal did not name the attributes file"
ok ".git/info/attributes is refused"
reset_checkout

# 5. The repository must be a plain directory.
runuser -u deploy -- mv /opt/deploy/.git /opt/deploy/.gitreal
runuser -u deploy -- ln -s .gitreal /opt/deploy/.git
if run >/tmp/out.log 2>&1; then fail "deploy proceeded with .git a symlink"; fi
grep -q 'not a plain directory' /tmp/out.log || fail "refusal did not name the git directory"
ok "a linked .git is refused"
reset_checkout

# 6. Compose variables in .env, in every form compose reads.
for line in 'COMPOSE_FILE=/tmp/x.yml' 'COMPOSE_FILE: /tmp/x.yml' 'COMPOSE_FILE =/tmp/x.yml' 'DOCKER_HOST=tcp://x:2375'; do
  runuser -u deploy -- sh -c "printf '%s\n' '$line' >/opt/deploy/.env"
  if run >/tmp/out.log 2>&1; then fail "deploy proceeded with '$line' in .env"; fi
  grep -q 'COMPOSE_\* or DOCKER_\*' /tmp/out.log || fail "refusal for '$line' was not the compose guard: $(cat /tmp/out.log)"
done
runuser -u deploy -- sh -c "printf 'BASE_URL=https://example.org:8443\n' >/opt/deploy/.env"
run >/tmp/out.log 2>&1 || fail "a benign .env value with a colon was refused: $(cat /tmp/out.log)"
ok "compose and docker variables in .env are refused; a benign value passes"
runuser -u deploy -- rm -f /opt/deploy/.env

# 7. An untracked hook is refused.
runuser -u deploy -- sh -c 'mkdir -p /opt/deploy/apps/y && printf "#!/bin/bash\necho y\n" >/opt/deploy/apps/y/deploy.sh && chmod +x /opt/deploy/apps/y/deploy.sh'
if run >/tmp/out.log 2>&1; then fail "deploy proceeded with an untracked hook"; fi
grep -q 'not tracked by git' /tmp/out.log || fail "refusal did not name the untracked hook"
ok "an untracked hook is refused"
reset_checkout

# 8. The rewind guard: a second commit deploys; a checkout and remote tip
#    moved back to the first commit (every other check passes: it is signed
#    content on the branch, clean, and equal to the remote tip) is refused;
#    --allow-rewind accepts it.
cd /srv/work && echo more >>docker-compose.yml && git commit -qam second && git push -q origin main && cd /
run >/tmp/out.log 2>&1 || fail "second commit refused: $(cat /tmp/out.log)"
second="$(git -C /opt/deploy rev-parse HEAD)"
[[ "$(cat /var/lib/vps-deploy/last-deployed)" == "$second" ]] || fail "second commit not recorded"
cd /srv/work && git reset -q --hard HEAD~1 && git push -q -f origin main && cd /
runuser -u deploy -- git -C /opt/deploy reset -q --hard HEAD~1
if run >/tmp/out.log 2>&1; then fail "a rewind to the older commit deployed"; fi
grep -q 'rewind' /tmp/out.log || fail "refusal did not mention the rewind: $(cat /tmp/out.log)"
run --allow-rewind >/tmp/out.log 2>&1 || fail "--allow-rewind was refused: $(cat /tmp/out.log)"
[[ "$(cat /var/lib/vps-deploy/last-deployed)" == "$(git -C /opt/deploy rev-parse HEAD)" ]] || fail "rewind not recorded"
ok "a rewind is refused unless --allow-rewind is passed"

# 9. --rollback is a release-tree form; checkout mode refuses it.
if run --rollback >/tmp/out.log 2>&1; then fail "--rollback accepted in checkout mode"; fi
ok "--rollback is refused in checkout mode"

# 10. A failed acceptance probe: the deploy stays live and recorded, the
#     housekeeping after the probes still runs, and the wrapper exits non-zero
#     so auto-deploy records the failure. Nothing is rolled back.
cd /srv/work && echo probed >>docker-compose.yml && git commit -qam third && git push -q origin main && cd /
touch /tmp/probes-fail
if run >/tmp/out.log 2>&1; then fail "the wrapper exited 0 with a failed probe"; fi
grep -q 'post-deploy probes failed' /tmp/out.log || fail "the probe failure was not reported last: $(cat /tmp/out.log)"
[[ "$(cat /var/lib/vps-deploy/last-deployed)" == "$(git -C /opt/deploy rev-parse HEAD)" ]] || fail "a probed-but-failed deploy was not recorded as deployed"
grep -q 'docker image prune' /tmp/docker.log || fail "the image prune did not run after a failed probe"
grep -q 'outcome=The deploy is live and has not been rolled back: this server deploys from a checkout, and automatic rollback needs the release tree' /tmp/docker.log || fail "the checkout layout did not tell the probes why nothing is rolled back: $(cat /tmp/docker.log)"
rm -f /tmp/probes-fail
ok "a failed probe exits non-zero after the housekeeping, with the deploy live, recorded and the alert saying why"

# ---------------------------------------------------------------------------
# The release tree (docs/15): the same template rendered with
# deploy_release_tree, against a stub vps-release that keeps the switch
# history, the hold and the releases the way the real one does, exported from
# a root mirror of the origin. What is under test is the wrapper's handling of
# a failed acceptance probe: an automatic rollback when no image or hook
# changed, and the alert's reason when it does not roll back.
python3 - <<'PY'
import jinja2
env = jinja2.Environment()
env.filters["bool"] = lambda v: v if isinstance(v, bool) else str(v).lower() in ("true", "1", "yes")
src = open("/t/templates/vps-deploy.j2").read()
out = env.from_string(src).render(deploy_release_tree=True, deploy_verify_signature=False, deploy_user="deploy", deploy_branch="main")
open("/usr/local/sbin/vps-deploy", "w").write(out)
PY
cat >/usr/local/sbin/vps-release <<'EOF'
#!/bin/bash
set -euo pipefail
echo "vps-release $*" >>/tmp/docker.log
STATE=/var/lib/vps-deploy; R=/opt/deploy-releases; H=$STATE/history
case "$1" in
  current) if [[ -L /opt/deploy ]]; then sed -n 's/^commit=//p' /opt/deploy/.release; else echo none; fi ;;
  prepare)
    [[ -d $STATE/repo.git ]] || git init -q --bare $STATE/repo.git
    git --git-dir=$STATE/repo.git fetch -q /srv/origin.git +refs/heads/main:refs/remotes/origin/main
    c="$(git --git-dir=$STATE/repo.git rev-parse refs/remotes/origin/main)"; d="$R/$c"
    if [[ ! -f "$d/.release" ]]; then
      mkdir -p "$d"; git --git-dir=$STATE/repo.git archive "$c" | tar -x -C "$d"
      printf 'commit=%s\nscaffold=none\nexported=now\n' "$c" >"$d/.release"
    fi
    echo "$d" ;;
  switch) if [[ -e /tmp/switch-fail && "$2" == "$(cat /tmp/switch-fail)" ]]; then exit 1; fi; ln -sfn "$2" /opt/.deploy-link && mv -T /opt/.deploy-link /opt/deploy; echo "now $2" >>"$H" ;;
  previous) cur="$(readlink -f /opt/deploy)"; tac "$H" | while read -r _ d; do if [[ "$d" != "$cur" ]]; then echo "$d"; break; fi; done; true ;;
  hold) echo "$2" >"$STATE/hold" ;;
  held) cat "$STATE/hold" 2>/dev/null || true ;;
  unhold) rm -f "$STATE/hold" ;;
  recheck|prune) ;;
  *) echo "stub: $*" >&2; exit 2 ;;
esac
EOF
chmod 0750 /usr/local/sbin/vps-deploy /usr/local/sbin/vps-release
mkdir -p /etc/vps-scaffold
printf 'REPO_URL=https://github.com/example/server\nBRANCH=main\nKEEP=3\nVERIFY_SIGNATURE=0\nPROBE_ROLLBACK=1\n' >/etc/vps-scaffold/release.env
rm -rf /opt/deploy /var/lib/vps-deploy/last-deployed
live() { sed -n 's/^commit=//p' /opt/deploy/.release; }
tip() { git -C /srv/work rev-parse HEAD; }
commit() { ( cd /srv/work && git add -A && git commit -qm "$1" && git push -q origin main ); }

# 11. A release deploys with its probes passing: no hold, the commit recorded.
echo base >>/srv/work/docker-compose.yml && commit "rt-base"
run >/tmp/out.log 2>&1 || fail "the first release deploy failed: $(cat /tmp/out.log)"
base="$(tip)"
[[ -L /opt/deploy && "$(live)" == "$base" ]] || fail "/opt/deploy is not the first release"
[[ "$(cat /var/lib/vps-deploy/last-deployed)" == "$base" ]] || fail "the first release was not recorded"
[[ -z "$(/usr/local/sbin/vps-release held)" ]] || fail "a passing deploy left a hold"
[[ ! -s /tmp/notify.log ]] || fail "a passing deploy notified: $(cat /tmp/notify.log)"
ok "a release whose probes pass is live, recorded and not held"

# 12. Probes fail, no image or hook changed (the unchanged hook still ran, as
#     hooks do on every deploy): the wrapper rolls back to the previous release,
#     re-probes it, records it, holds the failed commit and sends one alert
#     that names the host, the rollback and the unhold command.
: >/tmp/notify.log
echo bad >>/srv/work/docker-compose.yml && commit "rt-bad"
bad="$(tip)"; echo "$bad" >/tmp/probes-fail
if run >/tmp/out.log 2>&1; then fail "a rolled-back deploy exited 0: $(cat /tmp/out.log)"; fi
grep -q hook-ran /tmp/hook.log || fail "the unchanged hook did not run: $(cat /tmp/out.log)"
[[ "$(live)" == "$base" ]] || fail "/opt/deploy was not switched back to the previous release: $(cat /tmp/out.log)"
[[ "$(/usr/local/sbin/vps-release held)" == "$bad" ]] || fail "the failed commit is not held"
[[ "$(cat /var/lib/vps-deploy/last-deployed)" == "$base" ]] || fail "last-deployed does not name the release that is live again"
grep -q "^vps-release switch /opt/deploy-releases/$base$" /tmp/docker.log || fail "the switch back did not happen: $(cat /tmp/docker.log)"
[[ "$(grep -c '^probes /opt/deploy ' /tmp/docker.log)" == 2 ]] || fail "the previous release was not probed again: $(cat /tmp/docker.log)"
grep -q 'probes /opt/deploy notify= outcome=$' /tmp/docker.log || fail "the probes were not told to stay quiet: $(cat /tmp/docker.log)"
[[ "$(grep -c '^notify: ' /tmp/notify.log)" == 1 ]] || fail "expected exactly one alert: $(cat /tmp/notify.log)"
grep -q "^notify: Deploy probes failed: rolled back to ${base:0:7}$" /tmp/notify.log || fail "the alert title is wrong: $(cat /tmp/notify.log)"
grep -q '^app.example.org$' /tmp/notify.log || fail "the alert does not name the failing host"
grep -q "The previous release ${base:0:7} is live again and its probes passed." /tmp/notify.log || fail "the alert does not say the previous release is live again"
grep -q 'run sudo vps-release unhold' /tmp/notify.log || fail "the alert does not say how to resume automatic deploys"
grep -q 'previous release is live again' /tmp/out.log || fail "the closing line does not report the rollback: $(cat /tmp/out.log)"
grep -q 'docker image prune' /tmp/docker.log || fail "the housekeeping did not run after the rollback"
ok "probes fail with no image or hook changed: rolled back, re-probed, recorded, held and announced once"

# 13. The hold is honoured: --auto on the held commit exits 3 and changes
#     nothing; a new commit clears it and passes the rewind guard.
rc=0; run --auto >/tmp/out.log 2>&1 || rc=$?
[[ "$rc" != 0 ]] || fail "--auto deployed the held commit"
[[ "$rc" == 3 ]] || fail "--auto on the held commit exited $rc, expected 3: $(cat /tmp/out.log)"
[[ "$(live)" == "$base" ]] || fail "--auto moved /opt/deploy while the commit was held"
ok "--auto skips the held commit"

# 14. Probes fail on a deploy that changed an image: no rollback, the deploy
#     stays live and the alert says why. The new commit also clears the hold.
: >/tmp/notify.log
echo app:2 >/srv/work/images.txt && commit "rt-image"
imaged="$(tip)"; echo "$imaged" >/tmp/probes-fail
if run >/tmp/out.log 2>&1; then fail "a failed probe exited 0"; fi
[[ "$(live)" == "$imaged" ]] || fail "a deploy that changed an image was rolled back"
[[ -z "$(/usr/local/sbin/vps-release held)" ]] || fail "the hold was not cleared by the new commit, or the deploy held it"
[[ "$(cat /var/lib/vps-deploy/last-deployed)" == "$imaged" ]] || fail "the live deploy was not recorded"
grep -q 'outcome=The deploy is live and has not been rolled back, because it changed an image' /tmp/docker.log || fail "the alert does not give the image as the reason: $(cat /tmp/docker.log)"
[[ ! -s /tmp/notify.log ]] || fail "the wrapper sent an alert of its own as well as the probes': $(cat /tmp/notify.log)"
ok "probes fail after an image changed: not rolled back, and the alert says why"

# 14b. The same for a deploy that changed a hook.
printf '#!/bin/bash\necho hook-ran >>/tmp/hook.log\necho changed >/dev/null\n' >/srv/work/apps/x/deploy.sh
commit "rt-hook"
hooked="$(tip)"; echo "$hooked" >/tmp/probes-fail
if run >/tmp/out.log 2>&1; then fail "a failed probe exited 0"; fi
[[ "$(live)" == "$hooked" ]] || fail "a deploy that changed a hook was rolled back"
grep -q 'outcome=The deploy is live and has not been rolled back, because it changed an app deploy hook (apps/x/deploy.sh)' /tmp/docker.log || fail "the alert does not give the hook as the reason: $(cat /tmp/docker.log)"
ok "probes fail after a hook changed: not rolled back, and the alert says why"

# 15. Probes fail with automatic rollback switched off: no rollback, and the
#     alert says so.
sed -i 's/^PROBE_ROLLBACK=.*/PROBE_ROLLBACK=0/' /etc/vps-scaffold/release.env
echo off >>/srv/work/docker-compose.yml && commit "rt-off"
off="$(tip)"; echo "$off" >/tmp/probes-fail
if run >/tmp/out.log 2>&1; then fail "a failed probe exited 0"; fi
[[ "$(live)" == "$off" ]] || fail "a deploy was rolled back with deploy_probe_rollback off"
[[ -z "$(/usr/local/sbin/vps-release held)" ]] || fail "a hold was set with rollback off"
grep -q 'outcome=The deploy is live and has not been rolled back, because automatic rollback is switched off on this server (deploy_probe_rollback: false)' /tmp/docker.log || fail "the alert does not give the setting as the reason: $(cat /tmp/docker.log)"
sed -i 's/^PROBE_ROLLBACK=.*/PROBE_ROLLBACK=1/' /etc/vps-scaffold/release.env
ok "probes fail with rollback switched off: not rolled back, and the alert says why"

# 15b. A redeploy of the commit already live is not rolled back: the cause is
#      not a change this run made, and the previous release is older still.
if run >/tmp/out.log 2>&1; then fail "a failed probe exited 0"; fi
[[ "$(live)" == "$off" ]] || fail "a redeploy of the live commit was rolled back"
[[ -z "$(/usr/local/sbin/vps-release held)" ]] || fail "a redeploy set a hold"
grep -q 'outcome=The deploy is live and has not been rolled back, because this run redeployed the commit that was already live' /tmp/docker.log || fail "the alert does not give the redeploy as the reason: $(cat /tmp/docker.log)"
ok "a redeploy of the live commit whose probes fail stays, and the alert says why"

# 16. A hand-run --rollback whose probes fail is not rolled back again.
: >/tmp/notify.log
echo "$hooked" >/tmp/probes-fail
if run --rollback >/tmp/out.log 2>&1; then fail "a rollback with failing probes exited 0"; fi
[[ "$(live)" == "$hooked" ]] || fail "--rollback did not switch to the previous release: $(cat /tmp/out.log)"
[[ "$(/usr/local/sbin/vps-release held)" == "$off" ]] || fail "--rollback did not hold the commit rolled back from"
grep -q 'outcome=The release is live and has not been rolled back again, because this deploy was itself a rollback.' /tmp/docker.log || fail "a rollback's failed probes were not explained: $(cat /tmp/docker.log)"
grep -q "^notify: Rolled back to ${hooked:0:7}$" /tmp/notify.log || fail "the rollback was not announced: $(cat /tmp/notify.log)"
ok "a rollback whose probes fail stays, with the reason in the alert"

# 17. The switch back fails: the probes were silenced, so the wrapper must
#     alert itself and say that the failed commit is still live.
: >/tmp/notify.log
echo nosw >>/srv/work/docker-compose.yml && commit "rt-noswitch"
nosw="$(tip)"; echo "$nosw" >/tmp/probes-fail; echo "/opt/deploy-releases/$hooked" >/tmp/switch-fail
if run >/tmp/out.log 2>&1; then fail "a failed switch back exited 0"; fi
rm -f /tmp/switch-fail /tmp/probes-fail
[[ "$(live)" == "$nosw" ]] || fail "/opt/deploy moved although the switch failed"
grep -q '^notify: Deploy probes failed and the rollback did not start$' /tmp/notify.log || fail "a failed switch back was not announced: $(cat /tmp/notify.log)"
ok "a switch back that fails is announced, with the deploy live"

echo "all vps-deploy checks passed"
