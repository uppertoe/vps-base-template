# Access Model

**Status (2026-11-04): restricted mode is built and runs on both production
servers (RCH and MCH), on the release tree.** The split-trust model below is
built into the `deploy-user` and `docker` roles behind
`deploy_restricted_mode`. The role default stays **false** so that a new
server starts in the simpler model and is provisioned with the orchestrators,
which assume it; turn restricted mode on with the
[migration runbook](#migration-runbook) below once admin access is proven.
Molecule converges with the flag **on**, so CI continuously proves the
restricted posture.

In the default (unrestricted) mode the scaffold optimizes for simplicity:

- `deploy` can SSH into the host
- `deploy` has passwordless `sudo`
- `deploy` is in the `docker` group

That is operationally convenient, but it means `deploy` is effectively a
high-trust account. Compromise of `deploy` is close to host compromise — this
is a documented exception in
[08-security-model.md](08-security-model.md#exceptions-register), and
restricted mode is its closure.

In **restricted mode** (`deploy_restricted_mode: true`):

- `deploy` keeps SSH, but its sudoers file becomes a three-line allowlist for
  the root-owned wrappers `/usr/local/sbin/vps-deploy` (with no arguments:
  `--rollback` and `--allow-rewind` are for the admin account), `vps-app-manage`,
  `vps-app-logs` — and it is removed from the `docker` group.
- Restricted mode requires the **release tree** (`deploy_release_tree: true`,
  [15-release-tree.md](15-release-tree.md)) and the **signature gate**
  (`deploy_verify_signature: true`). The play refuses the mode without them.
  In the checkout layout root still reads, checks and executes files the
  deploy account owns, and the 2026-11-03 review showed that account could
  steer those checks; without the gate it owns the branch pointer root
  follows. A server mid-transition can accept the weaker posture explicitly
  with `deploy_restricted_checkout_ok: true` or
  `deploy_restricted_unsigned_ok: true`; the smoke test reports it.
- `admin` (created in both modes) is the break-glass operator: own key
  (dedicated key recommended — defaults to the deploy key), full sudo, docker
  group. **Ansible site plays must run as `admin`** (`ansible_user=admin`),
  since deploy can no longer become root.
- `~/deploy` still works — it delegates to `sudo vps-deploy`. Under the
  release tree root fetches and verifies the commit in its own mirror and
  exports it into a root-owned release (docs/15); in the checkout layout the
  wrapper runs git as `deploy` (repo ownership intact). Docker and the hooks
  run as root in both.
- `vps-app-manage <service> <verb>` executes only verbs listed in root-owned
  `/etc/vps-scaffold/app-manage.allow` (templated from
  `deploy_allowed_app_manage_commands`, default empty).

## Goal

Move from a single routine-and-privileged account to a split-trust model:

- `deploy`: routine deployment identity
- `admin`: break-glass operator identity

The aim is not to eliminate high-trust access. A web server still needs a
high-trust path for maintenance and incident response. The aim is to reduce how
often that level of trust is exercised.

## Target Model

### `deploy`

Intended purpose:

- normal releases
- controlled application maintenance commands
- reading application logs if explicitly permitted

Intended restrictions:

- SSH login allowed
- no unrestricted passwordless `sudo`
- not in the `docker` group
- no arbitrary `docker` or `docker compose` access

### `admin`

Intended purpose:

- break-glass host administration
- incident response
- direct Docker access when needed
- package/system repair

Intended privileges:

- separate SSH identity and key material
- `sudo` access
- either membership in `docker` or equivalent root-mediated Docker access

## Why This Model

This changes the trust distribution:

- current model:
  - routine deploy account is also the high-trust account
- target model:
  - routine deploy account is narrower
  - high-trust account exists, but is used deliberately and less often

That is a real security improvement even though `admin` remains powerful.

## Operational Consequences

The main tradeoff is flexibility versus control.

Because `deploy` is not allowed arbitrary Docker commands in restricted mode,
day-to-day operations go through approved entrypoints instead of free-form
shell access.

Commands that `deploy` can no longer type directly:

```bash
docker compose run --rm jw_django python manage.py migrate
docker compose exec jw_postgres psql ...
docker compose logs -f
```

Instead, `deploy` invokes the wrappers below, and anything else is done as
`admin`.

## Command Model

### Root-owned wrapper commands

The deploy-user role installs root-owned, audited entrypoints:

- `/usr/local/sbin/vps-deploy`
- `/usr/local/sbin/vps-app-manage`
- `/usr/local/sbin/vps-app-logs`

These wrappers are the only supported way for `deploy` to trigger app-level
container operations.

Two further root-owned helpers serve the administrator rather than the deploy
account; both are installed mode `0750`, so they are run with `sudo`:

- `/usr/local/sbin/vps-git` runs git for the administrator. Under the release
  tree it reads root's mirror (`git --git-dir /var/lib/vps-deploy/repo.git`),
  so `sudo vps-git log --oneline -5` shows what is deployed. In the checkout
  layout it runs git in `/opt/deploy` as the deploy account, with optional
  locks off, so `sudo vps-git status --short` never leaves a root-owned file
  behind. Plain `sudo git` in a checkout is the one known way to break the
  next deploy: git refreshes the index and rewrites it as root, and the deploy
  account can no longer open it (seen on 2026-11-01 and again on 2026-11-02).
- `/usr/local/sbin/vps-git-heal` hands back to the deploy account anything
  under `/opt/deploy/.git` that root has taken, removes a stale root-owned lock
  file, logs the repair and announces it over ntfy. `auto-deploy` and
  `vps-deploy` run it first, so a hand-run mistake no longer stops the next
  deploy; the alert still tells the operator it happened. It does nothing once
  `/opt/deploy` is a release link, because no repository is shared.

### Deploy entrypoint

`~/deploy` is the human-facing command. In restricted mode, and under the
release tree in either mode, it runs the root-owned wrapper:

```bash
sudo /usr/local/sbin/vps-deploy
```

`vps-deploy` performs the release workflow in this order:

1. Verify. Under the release tree root fetches the server repo into its own
   mirror, verifies the tip's signature against the root-owned trust stores
   and exports the commit into `/opt/deploy-releases/<commit>` (docs/15). In
   the checkout layout it checks the deploy-owned checkout as root (clean
   tree, branch and upstream, scaffold pointer, tracked hooks, the signature
   on HEAD) and refuses to proceed if any check fails.
2. Render the SOPS secrets (`vps-secrets-render`, docs/13) into the release or
   the checkout, and install `secrets/backup/` into `/etc/restic`.
3. `docker compose pull`; under the release tree the pull happens before the
   switch, so an unreachable registry leaves the running release in place.
4. Normalise permissions: the `.env` set to `600`, everything else containers
   mount to world-readable (checkout layout; a release is exported with git's
   modes).
5. Run each tracked `apps/*/deploy.sh` hook as root.
6. `docker compose up -d --remove-orphans --wait`, then the same with
   `--force-recreate` for only the services whose bind-mounted repo files this
   deploy changed (compose recreates image, definition and env changes itself).
7. Record the deployed commit in `/var/lib/vps-deploy/last-deployed`, then
   run the acceptance probes (`vps-deploy-probes`, below).
8. `docker image prune -af` (reclaim superseded images once the new containers
   are healthy). A failed probe is reported last, as a non-zero exit.

A hand-run `./deploy` on a default-mode server in the checkout layout does not
go through the wrapper: it pulls as the deploy account, renders the secrets
through `sudo`, still runs `docker compose up --force-recreate` for the
whole stack, and runs the same acceptance probes through `sudo`. The
automatic deploy always uses the wrapper.

### Acceptance probes

`compose up --wait` reports that every container is healthy. It does not
report that each site answers through Caddy as its access rules declare, and
a deploy that leaves a gate open or an app unreachable would otherwise be
counted a success. After the final `compose up`, `vps-deploy-probes` reads
the rendered access table (`.generated/caddy/route-access.tsv`, docs/04),
resolves `{$DOMAIN}` from the stack's `.env`, and asks the local Caddy for
the root of every site, over TLS on `127.0.0.1:443` with the host name
supplied through `--resolve`, following no redirects:

- A site whose rows are all gates (`groups`, `domains`, `signed-in`,
  `guests`) must answer `302` with a `Location` on the gateway's `/login`
  page. The same site is asked a second time with a forged
  `Remote-Email: forged@example.invalid` header and must still send that
  redirect, so the gate is known to run before the app and to strip client
  identity.
- A site whose rows are all `public` markers must answer 2xx or 3xx.
- A site with both kinds of row, or with a `network` row that opens it on a
  named network, may answer anything below 500 at its root (the box's own
  address is not on the named network, and the root may be a declared open
  path that answers 404).
- A 5xx, or no answer at all, fails the probe for any site. A failing probe
  is tried three times, ten seconds apart, before it counts.

A failure prints the failing hosts, sends one notification through
`vps-notify`, and makes the deploy exit non-zero, so `auto-deploy` records
the failure and the unit's `OnFailure` alert fires as well. Nothing is rolled
back: the deploy is live, and the operator decides whether to run
`sudo vps-deploy --rollback` (docs/15) or to fix forward. The probes test
routing and gating, not the certificate chain, so a site whose certificate is
still being issued fails only when Caddy cannot complete the handshake.

A host the box cannot answer for (DNS that still points elsewhere, so Caddy
holds no certificate for it) is listed in `deploy-probes.skip` at the root of
the server repo, one `host reason` per line, by its resolved name or its
address form:

```text
# host                reason
handbook.example.org  DNS moves to this box at the cut-over on Friday
planka.{$DOMAIN}      not yet deployed here
```

The file is read from the release, so it is committed and reviewed like any
other change, and each skipped host is printed with its reason on every
deploy. The probes can be run by hand at any time with
`sudo vps-deploy-probes /opt/deploy`.

### App maintenance entrypoint

For app-specific maintenance tasks, the wrapper exposes a narrow command
surface:

```bash
vps-app-manage journal-watch migrate
vps-app-manage journal-watch collectstatic
vps-app-manage journal-watch shell
```

The wrapper maps only approved verbs to fixed `docker compose` commands, read
from root-owned `/etc/vps-scaffold/app-manage.allow`. Unknown verbs are
rejected.

This preserves operational usefulness without giving `deploy` arbitrary Docker
control.

## Sudoers Model

The deploy-user role templates `/etc/sudoers.d/deploy` from
`deploy_restricted_mode`. In default mode it grants:

```text
deploy ALL=(ALL) NOPASSWD:ALL
```

In restricted mode it is the allowlist below, and nothing else. The empty
string after `vps-deploy` means the bare command only: `--rollback` and
`--allow-rewind` are for the admin account.

```text
deploy ALL=(root) NOPASSWD:/usr/local/sbin/vps-deploy ""
deploy ALL=(root) NOPASSWD:/usr/local/sbin/vps-app-manage *
deploy ALL=(root) NOPASSWD:/usr/local/sbin/vps-app-logs *
```

`admin` has `admin ALL=(ALL) NOPASSWD:ALL` in both modes.

## Docker Access Model

There are three practical choices:

1. `deploy` keeps `docker` group access
   - simplest
   - weakest separation
   - this is default mode

2. `deploy` loses `docker` group access, `admin` keeps it
   - the split-trust model
   - `admin` remains break-glass operator
   - this is restricted mode

3. nobody has ad hoc Docker access
   - strongest restriction
   - worst operational ergonomics for a small VPS

For this project, option 2 is the model in use.

## Incident Response

This model only works if incidents remain fixable quickly.

That means `admin` must retain an effective path to:

- `docker compose exec`
- `docker compose run`
- inspect database containers
- repair application state
- restart services manually

If `admin` cannot do that, the model becomes too restrictive for a small VPS.

## App Hook Compatibility

The scaffold already supports app-specific deploy hooks:

- `apps/<service>/deploy.sh`

That pattern can remain.

The change is only who invokes the hook:

- default mode, checkout layout:
  - `deploy` runs the hook directly with its own Docker access
- restricted mode, and the release tree in either mode:
  - root-owned `vps-deploy` invokes the hook under the controlled deployment
    path, from the release, which the hook must not write into

## Idempotence

This model is fully compatible with idempotent Ansible.

The idempotent parts are:

- creating `admin`
- creating or narrowing `deploy`
- group memberships
- sudoers files
- installing wrapper scripts
- permissions and ownership
- enabling/disabling login paths

The runtime deploy commands themselves are not configuration-idempotent in the
Ansible sense, but that is already true today and is not a blocker.

## Migration Runbook

Stages 1–3 of the original rollout plan (admin account, wrappers, the
`deploy_restricted_mode` flag) are implemented and applied on every site run.
To flip a live host to restricted mode **without locking yourself out**:

1. Run the site play as usual (`ansible_user=deploy`). This creates `admin`
   with its key, full sudo and docker group — restricted mode still off.
2. **Verify admin works before restricting anything:**
   `ssh admin@<host> 'sudo -n true && docker ps >/dev/null && echo ADMIN-OK'`
   (set a dedicated `deploy_admin_public_key` in the inventory first if you
   want separate key material — recommended).
3. In the inventory: set `deploy_restricted_mode=true` (as a host var or in
   `[servers:vars]`; since 2026-11-04 the flag is a role default, so an
   inventory group value is honoured), with `deploy_release_tree=true` and
   `deploy_verify_signature=true` (the play refuses restricted mode without
   them; see above), and switch `ansible_user=admin`. The play also refuses
   to narrow deploy's sudo while it is connected as the deploy account.
4. Re-run `site-quick.yml`. Deploy's sudoers becomes the wrapper allowlist and
   it leaves the docker group. The play also propagates any registry
   credentials from `~deploy/.docker/config.json` to root's docker config —
   in restricted mode `compose pull` runs as root inside `vps-deploy`, and
   without this every private-image pull fails "unauthorized". (If you
   `docker login` to a new registry later, log in as deploy and re-run the
   play, or copy the file to `/root/.docker/config.json` yourself.) Once the
   root copy exists you can delete `~deploy/.docker/config.json`: deploy
   cannot run docker anymore, so its copy of the registry token is pure
   exposure — notably to anything that reaches uid-1000 file access.
5. Verify: `bash scripts/post-provision-smoke-test.sh <admin-alias>` — the
   smoke test detects the mode from the user it CONNECTS as, so pass an SSH
   alias/host that connects as `admin`. Run against a deploy-user alias it
   assumes the default model and hangs on the first sudo check. Then confirm
   `ssh <host> ./deploy` still deploys (via `sudo vps-deploy`).
6. Rollback at any point: set the flag back to false and re-run the site play
   (idempotent in both directions). Update the docs/08 register entry with the
   flip date.

One inventory footgun when the plays run on the box itself (`-c local`, the
sane path for a slow operator link): both `deploy_user_public_key` /
`deploy_admin_public_key` must be set to LITERAL key strings — their defaults are file lookups of the connection key's
`.pub` on the controller, which is now the server, where your laptop's key
files don't exist (and `deploy_user_public_key` manages deploy's
authorized_keys, so a wrong fallback can swap deploy's key out from under
you).

To run a site play on the box **detached** (so a dropped operator link can't
kill it mid-hardening), start it as a transient **systemd** unit — not
`setsid`/`nohup &`. A non-lingering login session's user slice is torn down when
your SSH session ends, taking a backgrounded `setsid` job with it (`setsid`
escapes the controlling terminal, not the systemd user scope), and it dies
silently with no output. Run it in the system manager instead:

```bash
sudo systemd-run --unit=site-run \
  --uid=admin --gid=admin --setenv=HOME=/home/admin \
  --setenv=PYTHONUNBUFFERED=1 --property=WorkingDirectory=/home/admin/server-repo \
  ansible-playbook -i ansible/hosts -c local -l <host> \
  scaffold/ansible/site-first-run.yml
```

In restricted mode the play runs as `admin`, because the deploy account can
neither run `sudo systemd-run` nor become root; in default mode `deploy` works
too. The working directory must hold the inventory and the playbooks. On a
release-tree server `/opt/deploy` is a root-owned export of tracked files
only, so it holds no `ansible/hosts`: keep a clone of the server repo with
the inventory in admin's home and point `-i` at it, as above. In the checkout
layout `/opt/deploy` itself serves, when `ansible/hosts` has been placed
there.

Watch it with `journalctl -u site-run -f`; the unit survives the SSH drop, and
`systemctl show site-run -p ExecMainStatus` is the true play exit code (0 = ok).
Re-run after a failure needs `sudo systemctl reset-failed site-run` first.

## Variables

The role variables that shape the model, with their defaults
(`ansible/roles/deploy-user/defaults/main.yml`):

```yaml
deploy_restricted_mode: false           # the wrapper-only sudoers and no docker group
deploy_release_tree: false              # required by restricted mode (docs/15)
deploy_verify_signature: false          # required by restricted mode (below)
deploy_repo_url: ""                     # required by the release tree in restricted mode
deploy_admin_user: admin
deploy_admin_public_key: "{{ deploy_user_public_key }}"   # set a dedicated key
deploy_admin_key_allow_shared: false    # accept the shared key explicitly
deploy_allowed_app_manage_commands: {}  # verb -> command, per app
```

`deploy_allowed_app_manage_commands` is a map from verb to the command the
wrapper runs, not a list of verbs, for example
`migrate: "python manage.py migrate --noinput"`; it is templated into
`/etc/vps-scaffold/app-manage.allow`. `deploy_restricted_checkout_ok` and
`deploy_restricted_unsigned_ok` accept the weaker posture during a transition
and are reported by the smoke test.

## Access Review Cadence

**Quarterly**, review and record in the server repo (a dated markdown entry is
enough — it becomes control-matrix row 23 evidence):

- `~deploy/.ssh/authorized_keys` and `~admin/.ssh/authorized_keys` — every
  key still maps to a person who needs it
- `ADMIN_EMAILS` (and user activity) in the gateway's settings
  (`secrets/apps/auth/.env.sops` on a SOPS server, `apps/auth/.env` otherwise)
- credentials the box holds: backup S3 keys, SES/SMTP, registry tokens —
  rotate anything unexplained or older than 12 months
- dormant access: anything unused for ~45 days gets removed, not kept "just
  in case" (the Essential Eight ML2 dormancy rule, applied at our scale)

## The Repo-to-Root Trust Boundary

Be explicit about what restricted mode does NOT change: **anyone who can merge
to the server repo's default branch can execute code as root on the VPS.**

The chain: a merged commit lands in `/opt/deploy` on the next deploy; the
root-owned `vps-deploy` wrapper runs every executable `apps/*/deploy.sh` hook,
and hooks legitimately need Docker access (which is root-equivalent). With
`deploy_auto_update: true` and Renovate automerge, this happens with **no human
in the loop**.

Restricted mode confines the interactive SSH `deploy` user; it deliberately
does not confine the repo. The wrapper therefore executes only what git says
is at HEAD: it refuses a checkout off the deployed branch, any modified or
staged tracked file (including a dirty `scaffold` submodule), a compose
override file, or an untracked `apps/*/deploy.sh`. Without that, the deploy
user (which owns `/opt/deploy`) could place a hook or compose change that
never went through git and have root run it on the next deploy. GitHub
account security, branch protection, and review requirements ARE part of the
host's root boundary.
Treat them with the same seriousness as SSH keys:

- **Branch protection** on `main`: require PRs and passing CI; no force-push.
- **CODEOWNERS** on the executable surface (`apps/*/deploy.sh`, compose files,
  workflows, the `scaffold` submodule pointer) so those paths always require
  an owner's review — the instance template ships one.
- **Renovate cooldown** (`minimumReleaseAge`) applies to version bumps, which
  wait three days so a poisoned release can be pulled upstream before the
  deploy ships it. Digest bumps have no cooldown, because Renovate cannot date
  a digest (an undated update would stay pending forever, which froze the
  digest group from July 2026); a digest bump is a rebuild of the same tag,
  and CI plus the signed-deploy gate are its checks.
- **2FA + hardware keys** on any GitHub account with merge rights.

### Enforcing the boundary on the box: `deploy_verify_signature`

Branch protection lives in GitHub's plan tier (unavailable on free private
repos) and protects the repo, not the host. `deploy_verify_signature: true`
moves enforcement onto the box itself: `vps-deploy` runs
`git verify-commit HEAD` **as root**, with root-owned configuration only (an
explicit allowed-signers path and a fixed `GNUPGHOME`; the deploy user's git
config and keyring are not read, and the verifier programs, hooks path and
replace-ref handling are pinned on the command line so the deploy-owned
repository config cannot choose them), and refuses to deploy a HEAD it cannot
verify. Around that gate the wrapper also requires HEAD to equal the fetched
`origin/<branch>`, refuses a project `.env` that sets any `COMPOSE_*` variable
(the 2026-10-31 review), and makes every comparison with the checkout as root:
the working tree is compared with HEAD, the scaffold submodule's checkout with
the commit HEAD records and its own tree with that commit, the index flags are
read so a skip-worktree bit cannot hide an edited file, and each hook is
checked for being tracked, all with an isolated git configuration and a
private copy of the index that absorbs the stat refresh. The 2026-11-03
review found two ways the deploy-owned repository configuration could still
change the answer (a `core.worktree` pointing the comparison at a clean
copy, and a clean filter that ran as root during the index refresh), and two
root-side passes that followed symlinks in the deploy-owned tree. The wrapper
now passes the git and work-tree directories explicitly, requires them to be
plain directories at their expected places, reads the repository
configuration first and refuses any key that would run a program, redirect
the tree or include another file, refuses an attributes file under either git
directory, and runs its permission passes as the deploy account. It also
keeps a root-owned record of the last deployed commit and refuses a HEAD that
does not descend from it, so an older signed commit cannot be redeployed by
moving the branch; `--rollback` (release tree) and an explicit
`sudo vps-deploy --allow-rewind` by the admin account are the exceptions.
These are the belt-and-braces for the checkout layout; the release tree
removes the class, which is why restricted mode now requires it. The role
provisions two root-owned trust anchors:

- `/etc/ssh/allowed_signers` from `deploy_allowed_signers` — the
  operator's SSH signing key(s), for direct pushes to main.
- GitHub's web-flow GPG key (`deploy_trust_github_merges`, default true),
  downloaded at provision time. Only the keys whose primary fingerprints are
  on the allow-list `deploy_github_webflow_fingerprints` are imported into
  `/etc/vps-scaffold/gnupg`, and any other key found there is removed; the
  file GitHub serves also carries its 2017 key, expired in January 2024, which
  is deliberately not listed. This covers every commit GitHub's own merge
  machinery creates: web-UI merges and API merges, which is what Renovate
  automerge produces.

Net effect: PR merges and Renovate automerges deploy; a raw unsigned push
(stolen laptop token, a bot pushing directly) is refused and the failed deploy
pages via ntfy. Be clear about the breadth of the web-flow trust: a web-UI
edit on `main` or an API merge by ANY account or GitHub App with write access
produces a web-flow signature and deploys. On a free-plan private repo (no
branch protection) that makes every write-capable identity root-equivalent on
the host — this gate compensates for missing branch protection; it does not
replace account security or the scoping of app tokens.

Operator setup (once per machine that pushes directly to main):

```sh
ssh-keygen -t ed25519 -f ~/.ssh/git-signing -N "" -C "git-signing <email>"
git config gpg.format ssh
git config user.signingkey ~/.ssh/git-signing.pub
git config commit.gpgsign true          # per-repo, in the server repo
```

Then add `"<committer-email> <key-type> <base64-key>"` to
`deploy_allowed_signers` in the inventory and re-apply the deploy-user role.

In an INI inventory, write the list without outer quotes:
`deploy_allowed_signers=["<email> ssh-ed25519 AAAA..."]`. A value wrapped in
single quotes is read as one string, which would render one character per
line into `/etc/ssh/allowed_signers` and refuse every operator-signed deploy
(web-flow merges still verify through the GPG keyring, so the fault is easy
to miss). The deploy-user role fails the play on a string-valued
`deploy_allowed_signers` or `deploy_github_webflow_fingerprints` instead of
writing the file.
Cutover order matters: sign a commit on main FIRST (or merge any PR via
GitHub), then enable the gate — enabling it while HEAD is unsigned refuses
every deploy until a verifiable commit lands.

## What This Does Not Solve

This model improves access control, but it does not by itself solve:

- app-level secrets management
- container breakout risk inherent in privileged Docker access
- weak application authentication or authorization
- poor backup/restore procedures

It should be treated as one layer of hardening, not the whole security model.
