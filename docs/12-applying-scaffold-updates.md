# Applying scaffold updates to an existing box

The scaffold (`vps-base-template`) keeps improving — hardening fixes, new
controls, security patches to the roles. This runbook is how those reach a box
that is **already provisioned**. New boxes get the latest scaffold for free at
provision time; existing boxes do not, by design.

## Why this is a manual step

A server repo has **two update lanes**, and only one is automatic:

| Lane | What flows | How it applies | Speed |
|---|---|---|---|
| **Compose / Caddy** | app images, routes, the Caddy base | `auto-deploy` timer: `git pull` → `docker compose up` | ~24 h, hands-off |
| **Scaffold / Ansible** | hardening roles, audit tooling, watchers | **this runbook** — bump submodule + re-run `site-quick` | operator-gated |

The Ansible lane is deliberately **not** auto-applied: a role change can carry
an operator action (a new required inventory var, a one-way migration), so it
must not run unattended as root. Instead the `scaffold-drift-check` timer
(weekly) alerts via ntfy when your `scaffold/` submodule is behind upstream
`main`. This runbook is what you do when that alert fires.

## The update

1. **See the drift** — either the weekly ntfy alert, or on demand:
   ```bash
   git -C scaffold fetch origin
   git -C scaffold log --oneline HEAD..origin/main   # what you're missing
   ```

2. **Review before applying.** Read the base-template commit messages / release
   notes for the range above. Anything that says *BREAKING*, *UPGRADING*, or
   introduces a new required inventory var is an operator action — note it now.

3. **Bump the submodule pointer** (a commit in your server repo, so the change
   is reviewable and revertible):
   ```bash
   git -C scaffold checkout origin/main        # or a specific reviewed SHA
   git add scaffold && git commit -m "chore: bump scaffold to <sha> (security fixes)"
   ```

4. **Dry-run** (optional but cheap — shows what would change without touching
   the box):
   ```bash
   cd scaffold/ansible
   ansible-playbook -i ../../ansible/hosts site-quick.yml --check --diff
   ```

5. **Apply** the hardening. `site-quick` is the fast idempotent re-apply (it
   skips the slow compliance scans that `site-first-run` runs):
   ```bash
   ansible-playbook -i ../../ansible/hosts site-quick.yml
   ```
   Run it from `scaffold/ansible/` (or set `ANSIBLE_CONFIG`) so the
   transport-resilience settings apply — see docs/09. Expect **0 failed**.

6. **Verify.** Run the audit bundle (or at least the smoke test + the §5 audit
   that the new controls live in) and confirm the box still passes:
   ```bash
   ansible-playbook -i ../../ansible/hosts audit-all.yml
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

Set the var (or the explicit opt-out) in your inventory and re-run. Each opt-out
is a documented, deliberate acceptance — not a default you can drift into.

## Rollback

The submodule pointer is just a git ref. If an update misbehaves:
```bash
git revert <the bump commit>          # or: git -C scaffold checkout <old sha>
git add scaffold && git commit
cd scaffold/ansible && ansible-playbook -i ../../ansible/hosts site-quick.yml
```
The roles are idempotent, so re-applying the previous scaffold restores the
previous posture. (A change that altered on-disk data rather than config is the
exception — those are flagged UPGRADING in step 2.)

## Cadence

- **Security-relevant** scaffold updates: apply promptly (the drift alert tells
  you it is waiting).
- **Routine** updates: batch them at your monthly maintenance window
  (`maintenance-day.yml` opens the reminder issue).
- After applying, the `scaffold-drift-check` alert clears on its next run — a
  quiet drift channel means you are current.
