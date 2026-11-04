# Applying scaffold updates to an existing box

The scaffold (`vps-base-template`) keeps improving — hardening fixes, new
controls, security patches to the roles. This runbook is how those reach a box
that is **already provisioned**. New boxes get the latest scaffold at provision
time; on an existing box the compose and Caddy parts of a scaffold change
arrive by themselves, and the host layer waits for you.

## The two lanes

A server repo has **two update lanes**, and only one is automatic:

| Lane | What flows | How it applies | Speed |
|---|---|---|---|
| **Compose / Caddy** | app images, routes, the Caddy base, `run-caddy.sh`, the route renderer | Renovate bumps the `scaffold` pointer and the image digests, CI proves the merged stack, Renovate automerges, and `auto-deploy` ships it | within minutes when the push trigger is on, otherwise at the next daily run |
| **Scaffold / Ansible** | hardening roles, timers, scripts, the wrappers | **this runbook**: a site play, run by an operator | operator-gated |

On a server where Renovate manages the `scaffold` submodule (every server
made from the instance template), Renovate opens the bump pull request, its
post-upgrade task runs `scripts/check-server-files.sh --fix` so the shared
files and workflow callers match the new commit, CI passes, and the merge
deploys. By the time you read this runbook the pointer is already bumped,
merged and deployed: `run-caddy.sh`, the compose base and the route renderer
are live. What is not live is anything a role installs.

The Ansible lane is deliberately **not** auto-applied: a role change can carry
an operator action (a new required inventory var, a one-way migration), so it
must not run unattended as root. Two alerts tell you when it is waiting:

- **"Host play due"**, sent by `vps-deploy` when a deploy moved the scaffold
  pointer, and repeated weekly by the `scaffold-drift-check` timer while the
  deployed scaffold differs from the commit the last site play applied
  (`/var/lib/vps-site-applied`).
- **"Scaffold N commit(s) behind upstream"**, from the same timer, when the
  pointer itself is behind the scaffold's `main`. On a Renovate-managed server
  this clears by itself once the bump merges.

## The update

1. **See the drift**, from the alert or on demand. On a release-tree
   server the deployed scaffold commit is in `/opt/deploy/.release`; on a
   checkout server it is the submodule's HEAD. The alert names both commits.
   In the server repo:
   ```bash
   git -C scaffold log --oneline <applied>..HEAD   # what the host layer is missing
   ```

2. **Review before applying.** Read the base-template commit messages and the
   [UPGRADING.md](../UPGRADING.md) entries for the range above. Anything that
   says *BREAKING*, *UPGRADING*, or introduces a new required inventory var is
   an operator action — note it now.

3. **Bump the pointer, if Renovate has not.** On a Renovate-managed server
   skip this step: the pointer is already bumped. Where you bump by hand,
   follow docs/14 "Bumping the pointer": check out the commit, run
   `bash scaffold/scripts/server/check-server-files.sh --fix` and
   `bash scaffold/docker/render-caddy-routes.sh`, review `git status`, and
   commit everything the check wrote. A bump commit without the refreshed
   files fails CI on drift.

4. **Dry-run** (optional but cheap — shows what would change without touching
   the box). From the server repo root, where `ansible.cfg` applies the
   transport settings:
   ```bash
   ansible-playbook -i ansible/hosts scaffold/ansible/site-quick.yml --check --diff
   ```
   On a restricted-mode server the inventory's `ansible_user=admin` makes the
   plays run as admin, because the deploy account cannot become root; do not
   override it with `-u deploy`.

5. **Apply** the hardening. `site-quick` is the fast idempotent re-apply (it
   skips the slow compliance scans that `site-first-run` runs):
   ```bash
   ansible-playbook -i ansible/hosts scaffold/ansible/site-quick.yml
   ```
   Expect **0 failed**. Over a slow or lossy link, run the play on the box
   itself as a transient systemd unit (docs/05 "Migration runbook").

6. **Verify.** Run the audit bundle (or at least the smoke test + the §5 audit
   that the new controls live in) and confirm the box still passes:
   ```bash
   ansible-playbook -i ansible/hosts scaffold/ansible/audit-all.yml
   ```

## Fail-fast is a feature, not a breakage

Newer scaffold versions **refuse to provision** a box that is missing a control
rather than silently shipping without it. If `site-quick` stops with a `fail:`
message, it is telling you an operator action from step 2:

- `notify_deadman_url` unset → set it, or `notify_deadman_accept_none: true`
- `notify_ntfy_url` unset → set it, or `notify_alerts_accept_none: true`
- `log_export_s3_uri` unset (with export enabled) → set it, or
  `log_export_accept_none: true`
- admin key == deploy key in restricted mode → give admin a **dedicated** key
  (docs/05), or `deploy_admin_key_allow_shared: true`
- restricted mode without the release tree or the signature gate → set
  `deploy_release_tree: true` and `deploy_verify_signature: true` (docs/15,
  docs/05), or accept the transition posture with
  `deploy_restricted_checkout_ok: true` / `deploy_restricted_unsigned_ok: true`

Set the var (or the explicit opt-out) in your inventory and re-run. Each opt-out
is a documented, deliberate acceptance — not a default you can drift into.

## Rollback

The submodule pointer is just a git ref. If an update misbehaves:
```bash
git revert <the bump commit>          # or: git -C scaffold checkout <old sha>
bash scaffold/scripts/server/check-server-files.sh --fix
git add -A && git commit
ansible-playbook -i ansible/hosts scaffold/ansible/site-quick.yml
```
The roles are idempotent, so re-applying the previous scaffold restores the
previous posture. (A change that altered on-disk data rather than config is the
exception — those are flagged UPGRADING in step 2.) The compose layer rolls
back with the revert's deploy; on a release-tree server
`sudo vps-deploy --rollback` as admin switches to the previous release without
a commit.

## Cadence

- **Security-relevant** scaffold updates: apply promptly (the "Host play due"
  alert tells you one is waiting).
- **Routine** updates: batch them at your monthly maintenance window
  (`maintenance-day.yml` opens the reminder issue).
- After applying, the alerts clear on their next run — a quiet drift channel
  means you are current.
