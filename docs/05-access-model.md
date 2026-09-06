# Access Model

**Status: implemented as a staged rollout.** The split-trust model below is
built into the `deploy-user` and `docker` roles behind
`deploy_restricted_mode` (default **false** — the simple model — until the
restricted path is proven on your real VPS). Molecule converges with the flag
**on**, so CI continuously proves the restricted posture. See the
[migration runbook](#migration-runbook) below to flip a live host.

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
  the root-owned wrappers `/usr/local/sbin/vps-deploy`, `vps-app-manage`,
  `vps-app-logs` — and it is removed from the `docker` group.
- `admin` (created in both modes) is the break-glass operator: own key
  (dedicated key recommended — defaults to the deploy key), full sudo, docker
  group. **Ansible site plays must run as `admin`** (`ansible_user=admin`),
  since deploy can no longer become root.
- `~/deploy` still works — it delegates to `sudo vps-deploy`, which runs git
  as `deploy` (repo ownership intact) and docker/hooks as root.
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

If `deploy` is no longer allowed arbitrary Docker commands, then day-to-day
operations need approved entrypoints instead of free-form shell access.

Examples of commands that would no longer be typed directly by `deploy`:

```bash
docker compose run --rm jw_django python manage.py migrate
docker compose exec jw_postgres psql ...
docker compose logs -f
```

Instead, `deploy` would invoke approved wrappers.

## Proposed Command Model

### Root-owned wrapper commands

Install root-owned, audited entrypoints such as:

- `/usr/local/sbin/vps-deploy`
- `/usr/local/sbin/vps-app-manage`
- `/usr/local/sbin/vps-app-logs`

These wrappers become the only supported way for `deploy` to trigger app-level
container operations.

### Deploy entrypoint

`~/deploy` would remain the human-facing command, but instead of relying on
unrestricted Docker access it would call a controlled root-owned wrapper.

Conceptually:

```bash
sudo /usr/local/sbin/vps-deploy
```

`vps-deploy` would perform the existing release workflow:

- update the repo
- update submodules
- normalize `.env` permissions
- run approved app deploy hooks
- `docker compose pull`
- `docker compose up -d --remove-orphans --wait`
- `docker image prune -af` (reclaim superseded images once the new containers are healthy)

### App maintenance entrypoint

For app-specific maintenance tasks, expose a narrow command surface.

Examples:

```bash
vps-app-manage journal-watch migrate
vps-app-manage journal-watch collectstatic
vps-app-manage journal-watch shell
```

The wrapper would map only approved verbs to fixed `docker compose` commands.
Unknown verbs would be rejected.

This preserves operational usefulness without giving `deploy` arbitrary Docker
control.

## Sudoers Model

The current scaffold grants:

```text
deploy ALL=(ALL) NOPASSWD:ALL
```

The future restricted model should replace that with a minimal allowlist.

Example direction:

```text
deploy ALL=(root) NOPASSWD:/usr/local/sbin/vps-deploy
deploy ALL=(root) NOPASSWD:/usr/local/sbin/vps-app-manage *
deploy ALL=(root) NOPASSWD:/usr/local/sbin/vps-app-logs *
```

The exact `sudoers` surface should be kept small and explicit.

## Docker Access Model

There are three practical choices:

1. `deploy` keeps `docker` group access
   - simplest
   - weakest separation

2. `deploy` loses `docker` group access, `admin` keeps it
   - preferred split-trust model
   - `admin` remains break-glass operator

3. nobody has ad hoc Docker access
   - strongest restriction
   - worst operational ergonomics for a small VPS

For this project, option 2 is the best target.

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

- current model:
  - `deploy` runs the hook directly with its own Docker access
- future model:
  - root-owned `vps-deploy` invokes the hook under the controlled deployment
    path

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
3. In the inventory: set `deploy_restricted_mode=true` as a host var and
   switch `ansible_user=admin`.
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

Two inventory footguns when the plays run on the box itself (`-c local`, the
sane path for a slow operator link): `deploy_restricted_mode` must be a HOST
var (a playbook group_vars default of false outranks inventory group vars),
and both `deploy_user_public_key` / `deploy_admin_public_key` must be set to
LITERAL key strings — their defaults are file lookups of the connection key's
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
  --uid=deploy --gid=deploy --setenv=HOME=/home/deploy \
  --setenv=PYTHONUNBUFFERED=1 --property=WorkingDirectory=/opt/deploy \
  ansible-playbook -i ansible/hosts -c local -l <host> \
  scaffold/ansible/site-first-run.yml
```

Watch it with `journalctl -u site-run -f`; the unit survives the SSH drop, and
`systemctl show site-run -p ExecMainStatus` is the true play exit code (0 = ok).
Re-run after a failure needs `sudo systemctl reset-failed site-run` first.

## Suggested Variables

Possible future variables:

```yaml
deploy_restricted_mode: false
deploy_admin_user: admin
deploy_admin_public_key: "{{ lookup('file', '~/.ssh/id_ed25519.pub') }}"
deploy_allow_direct_docker_for_admin: true
deploy_allowed_app_manage_commands:
  - migrate
  - collectstatic
  - shell
```

## Access Review Cadence (applies today)

Unlike the target model above, this is current practice, not aspiration:
**quarterly**, review and record in the server repo (a dated markdown entry is
enough — it becomes control-matrix row 23 evidence):

- `~deploy/.ssh/authorized_keys` — every key still maps to a person who needs it
- `ADMIN_EMAILS` (and user activity) in `apps/auth/.env`
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
does not confine the repo. That means GitHub account security, branch
protection, and review requirements ARE part of the host's root boundary.
Treat them with the same seriousness as SSH keys:

- **Branch protection** on `main`: require PRs and passing CI; no force-push.
- **CODEOWNERS** on the executable surface (`apps/*/deploy.sh`, compose files,
  workflows, the `scaffold` submodule pointer) so those paths always require
  an owner's review — the instance template ships one.
- **Renovate cooldown** (`minimumReleaseAge`): automerged digest bumps must
  age upstream before they can reach the box, so a poisoned release is caught
  by the ecosystem before your deploy timer ships it.
- **2FA + hardware keys** on any GitHub account with merge rights.

### Enforcing the boundary on the box: `deploy_verify_signature`

Branch protection lives in GitHub's plan tier (unavailable on free private
repos) and protects the repo, not the host. `deploy_verify_signature: true`
moves enforcement onto the box itself: `vps-deploy` runs
`git verify-commit HEAD` as the deploy user and refuses to deploy a HEAD it
cannot verify. The role provisions two root-owned trust anchors:

- `/etc/ssh/allowed_signers` from `deploy_allowed_signers` — the
  operator's SSH signing key(s), for direct pushes to main.
- GitHub's web-flow GPG key (`deploy_trust_github_merges`, default true) —
  covers every commit GitHub's own merge machinery creates: web-UI merges and
  API merges, which is what Renovate automerge produces.

Net effect: PR merges and Renovate automerges deploy; a raw unsigned push
(stolen laptop token, compromised bot pushing directly) is refused and the
failed deploy pages via ntfy. An attacker with full account control can still
merge through a PR — this gate compensates for missing branch protection; it
does not replace account security.

Operator setup (once per machine that pushes directly to main):

```sh
ssh-keygen -t ed25519 -f ~/.ssh/git-signing -N "" -C "git-signing <email>"
git config gpg.format ssh
git config user.signingkey ~/.ssh/git-signing.pub
git config commit.gpgsign true          # per-repo, in the server repo
```

Then add `"<committer-email> <key-type> <base64-key>"` to
`deploy_allowed_signers` in the inventory and re-apply the deploy-user role.

> **INI inventory pitfall:** write the list *without* outer quotes —
> `deploy_allowed_signers=["<email> ssh-ed25519 AAAA…"]`. Wrapped in single
> quotes the value parses as a *string*, which would render one character per
> line into `/etc/ssh/allowed_signers` and refuse every operator-signed deploy
> (Renovate automerges still verify via GitHub's web-flow key, masking the
> break). The deploy-user role now fails the play on a string-valued var
> instead of writing the corrupt file.
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
