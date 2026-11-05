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
if [ "$1 $2" = "compose config" ]; then echo '{"services":{}}'; fi
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' >/usr/local/sbin/vps-git-heal
printf '#!/bin/sh\nexit 0\n' >/usr/local/sbin/vps-secrets-render
# The acceptance probes record their call and fail when /tmp/probes-fail exists.
printf '#!/bin/sh\necho "probes $*" >>/tmp/docker.log\n[ -e /tmp/probes-fail ] && exit 1\nexit 0\n' >/usr/local/sbin/vps-deploy-probes
# shellcheck disable=SC2016  # the $1 is for the stub, not this shell
printf '#!/bin/sh\necho "notify: $1" >>/tmp/notify.log\nexit 0\n' >/usr/local/bin/vps-notify
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
grep -A99 'docker compose up' /tmp/docker.log | grep -q '^probes /opt/deploy$' || fail "the acceptance probes did not run after compose up: $(cat /tmp/docker.log)"
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
rm -f /tmp/probes-fail
ok "a failed probe exits non-zero after the housekeeping, with the deploy live and recorded"

echo "all vps-deploy checks passed"
