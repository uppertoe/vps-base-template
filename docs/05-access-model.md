# Access Model

This document describes a future access-control model for the scaffold. It is
not the current implementation.

The current scaffold intentionally optimizes for simplicity:

- `deploy` can SSH into the host
- `deploy` has passwordless `sudo`
- `deploy` is in the `docker` group

That is operationally convenient, but it means `deploy` is effectively a
high-trust account. Compromise of `deploy` is close to host compromise.

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

## Recommended Rollout Strategy

This should not replace the current model in one step.

Recommended sequence:

1. add `admin` account support
2. add root-owned wrapper scripts
3. add an optional `restricted_deploy_mode` variable
4. when enabled:
   - remove `deploy` from `docker`
   - replace broad `sudo` with wrapper-only `sudo`
5. keep the current model as default until the restricted path is proven on a
   real VPS

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

## What This Does Not Solve

This model improves access control, but it does not by itself solve:

- app-level secrets management
- container breakout risk inherent in privileged Docker access
- weak application authentication or authorization
- poor backup/restore procedures

It should be treated as one layer of hardening, not the whole security model.
