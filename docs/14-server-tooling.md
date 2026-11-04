# Server tooling: one canonical set, carried by the pointer

Everything a server repo runs against itself in CI, and every operator script
it ships, lives in this scaffold. A server repo carries only thin copies that
GitHub or an operator needs to find in the repo itself, and a check keeps
those copies equal to the scaffold's. Bumping the `scaffold` pointer therefore
carries a tooling fix to every server; nothing is patched per repo.

## What lives where

| In the scaffold | In each server repo |
|---|---|
| `scripts/server/*.sh`, `*.py`, `lib/` : the checks and operator scripts (image pins, template consistency, compose smoke test, forward-auth test, digest freshness, update pipeline, recovery bundle for servers without SOPS, provision, restore, the AWS setup helpers) | `scripts/<same name>` : a five-line shim that sets `SERVER_ROOT` and runs the scaffold's copy, so `bash scripts/check-image-pins.sh` works unchanged |
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

Three things the check holds that `--fix` cannot write, because they are the
server's own text. The `.gitignore` must still ignore the secret paths the
canonical block exists for (`.env`, an app's `.env`, `backup/config.env`, a
recovery bundle, the compose override, `ansible/hosts`) once the server's own
lines below the block have been read; a later `!.env` is reported and must be
removed by hand. A workflow under `.github/workflows/` that the manifest does
not name is listed, with any write permission it asks for, and is refused if
it runs on `pull_request_target`. And `.scaffold-server.yml` must carry only
the four known keys, with `true` or `false` written exactly and a
40-character commit for `gateway_ref` whenever `gateway_chain` is true,
since the shared CI reads the file with a plain parser and a value it cannot
read would turn a check off without a word.

The shared CI runs every check from the scaffold submodule itself
(`scaffold/scripts/server/<name>`, with `SERVER_ROOT` set to the server's
checkout), never through the server's `scripts/` shims. The shims exist for
operators at the keyboard; in CI they are files the drift check compares, and
a shim edited in the pull request must not be what runs the drift check.

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

The two callers that take a secret (`ci.yml` and `container-security.yml`)
pass `GHCR_READ_TOKEN` by name and nothing else. The reusable workflows
declare that one secret as optional, so a server without the token still
runs them with the repository's own token, and the server's other secrets
(deploy tokens, cloud keys) never reach a job that runs images from a pull
request.

The compose smoke test checks the CIS Docker section 5 block twice: once as
declared, over every service in the resolved compose config, with the same
checker and the same exceptions register `audit-compose.yml` uses on the
host, and once at runtime on the containers it starts. A new app whose
compose file lacks the block therefore fails the pull request, and the
"every app container must carry the section 5 block" rule in a server's
CLAUDE.md is enforced before merge rather than discovered by the first audit
after deploy.

## Action digests in the server workflows

Every `uses:` in the canonical workflows is pinned to a commit digest.
Renovate's GitHub Actions manager looks only under a repository's own
`.github/`, so a server's Renovate would otherwise bump the digests in its
copies, and the drift check would then refuse the pull request; each server's
`renovate.json5` lists the managed workflow files under `ignorePaths` for
that reason. The scaffold's own `renovate.json5` instead adds
`server-files/.github/workflows/` to the manager's file patterns, so the
digests are bumped once, in the canonical copy, with the same grouping and
automerge as the scaffold's own workflows, and reach every server through the
next scaffold bump and `check-server-files.sh --fix`.

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
git status                                                 # review what the check wrote
git add -A && git commit
```

`git add -A` after reviewing `git status`, because besides `scaffold`,
`scripts`, `.github` and `.generated` the check may also write root files
such as `ansible.cfg`, `Caddyfile.local`,
`docker-compose.override.yml.example` and the `.gitignore` block, and seed
`.scaffold-server.yml`; a file left unstaged fails CI on drift.

On a server where Renovate manages the submodule, its scaffold bump runs the
same `check-server-files.sh --fix` as a post-upgrade task in the branch
(`renovate.json5` in the server repo, allow-listed on the fleet runner), so
the pull request carries the refreshed files. Renovate does not run the
renderer; if a bump changes the rendered routes, CI reports the drift and the
re-render is committed by hand.

## Adding a shared script

Put it in `scripts/server/`, find the server root as the others do
(`ROOT_DIR="${SERVER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"`),
add a shim under `server-files/scripts/` and a line to `MANIFEST`. The
scaffold's own CI shellchecks both.
