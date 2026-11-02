# Server tooling: one canonical set, carried by the pointer

Everything a server repo runs against itself in CI, and every operator script
it ships, lives in this scaffold. A server repo carries only thin copies that
GitHub or an operator needs to find in the repo itself, and a check keeps
those copies equal to the scaffold's. Bumping the `scaffold` pointer therefore
carries a tooling fix to every server; nothing is patched per repo.

## What lives where

| In the scaffold | In each server repo |
|---|---|
| `scripts/server/*.sh`, `*.py`, `lib/` : the checks and operator scripts (image pins, template consistency, compose smoke test, forward-auth test, digest freshness, update pipeline, recovery bundle, provision, restore, the AWS setup helpers) | `scripts/<same name>` : a five-line shim that sets `SERVER_ROOT` and runs the scaffold's copy, so `bash scripts/check-image-pins.sh` works unchanged |
| `.github/workflows/server-ci.yml`, `server-container-security.yml`, `server-secret-scan.yml` : reusable workflows holding the jobs | `.github/workflows/ci.yml`, `container-security.yml`, `secret-scan.yml` : the triggers only, each calling the scaffold's workflow at the commit the submodule is at |
| `server-files/` : the canonical copy of every server-side file above, plus `deploy-ping.yml`, `digest-freshness.yml`, `maintenance-day.yml`, the optional `codeql.yml`, `scorecard.yml` and `update-pipeline-freshness.yml`, `ansible.cfg`, `Caddyfile.local`, `docker-compose.override.yml.example`, and the `.gitignore` block | the same files, byte for byte |
| `server-files/MANIFEST` : which files, and how closely each must match | `.scaffold-server.yml` : this server's choices |
| `docs/templates/` : the one set of compliance evidence templates | `compliance/` : the filled pack for that server |

Per-server content stays per server: the `include:` list in
`docker-compose.yml`, `apps/`, `ansible/audit-exceptions.yml`,
`scripts/update-pipeline-state.json`, `.env.example`, `renovate.json5`'s
first-party package list, the compliance pack and any design docs.

## The check

```bash
bash scripts/check-server-files.sh          # report drift; exit 1 if any
bash scripts/check-server-files.sh --fix    # write the canonical copies
```

The CI workflow runs the check first, so a server whose copies have drifted
fails CI with the command that fixes it. The manifest kinds are `exact`
(byte for byte), `ref` (byte for byte except that the workflow's
`@<commit>` must be the submodule commit), `block` (the canonical text must
appear verbatim; the server may add lines, as it does for `.gitignore`),
`optional` (if present, exact) and `seed` (copied once, then the server's
own).

## How a server's CI chooses what to run

The shared CI reads `.scaffold-server.yml` in the server repo:

```yaml
gateway_chain: true        # run the gateway's end-to-end suite against apps/auth/auth.caddy
gateway_ref: <commit>      # of uppertoe/vps-scaffold-auth; bump with the gateway image
image_provenance: true     # first-party digests must come from their source repo's main
secrets_sops: true         # secrets/*.sops must be encrypted; no env file tracked
```

The forward-auth test runs whenever `apps/auth/auth.caddy` exists. The
optional workflows (CodeQL, Scorecard, update-pipeline freshness) run on a
server only if that server carries the file; a server short of Actions
minutes leaves them out, and the check still verifies the ones it has.

## Why the workflow reference is a commit, not `main`

A server's `ci.yml` calls `server-ci.yml@<commit>`, and `--fix` sets that
commit to the submodule's. The jobs a server runs are therefore the ones its
pinned scaffold ships, reviewed in the server repo when the pointer moves,
and a change on the scaffold's `main` reaches no server until it is bumped
there. The scripts the jobs run come from the server's own checkout of the
submodule for the same reason.

## Bumping the pointer

```bash
git -C scaffold fetch && git -C scaffold checkout <commit>
bash scaffold/scripts/server/check-server-files.sh --fix   # the shims may be new
bash scaffold/docker/render-caddy-routes.sh                # the renderer may have changed
git add scaffold scripts .github .gitignore .generated && git commit
```

## Adding a shared script

Put it in `scripts/server/`, find the server root as the others do
(`ROOT_DIR="${SERVER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"`),
add a shim under `server-files/scripts/` and a line to `MANIFEST`. The
scaffold's own CI shellchecks both.
