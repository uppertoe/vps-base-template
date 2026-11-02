# Secrets: SOPS-encrypted in git, Docker secrets at runtime

**Status: proposed (2026-11-02).** Nothing here is built yet. The owner has
made both decisions below; building waits for this document to be merged.

## The problem this solves

Each server holds its secrets as plaintext `.env` files under `/opt/deploy`,
edited by hand over SSH. The only other copies are the encrypted env-files
backup and the recovery bundle, which an operator has to remember to refresh.
Four costs follow from that:

- A change to a secret has no history, no author and no review, and it cannot
  be reverted.
- A rebuild depends on a recovery bundle being current. A stale bundle is a
  quiet failure that surfaces only during an outage.
- Hand edits leave copies behind (`.env.bak`, `/root/*-env.bak-*`) and leave
  dead values in place, such as an `OIDC_CLIENT_SECRET` that nothing reads.
- Every container receives its secrets as environment variables. Docker keeps
  those in plaintext in each container's configuration on disk, shows them to
  anyone who can run `docker inspect`, and passes them to every child process.

## The design in one paragraph

Secrets live in git, encrypted with [SOPS](https://github.com/getsops/sops)
using [age](https://age-encryption.org) keys. Each server has its own age key,
held root-only on the box. The owner has one key for editing and one offline
recovery key. At deploy, the root-run wrapper decrypts the files and writes the
`.env` files that Compose already reads. The apps do not change in phase 1. In
phase 2, the most valuable secrets move from environment variables to Docker
secrets, which are files mounted into only the container that needs them.

## Keys

| Key | Where the private half lives | Can decrypt |
|---|---|---|
| Server key (one per server) | `/etc/vps-scaffold/age/key.txt` on that server, root `0400` | that server's secrets only |
| Owner key | the owner's laptop and password manager | every server's secrets |
| Recovery key | offline: printed and in the password manager, never on a computer in daily use | every server's secrets |

The public halves are recorded in `.sops.yaml` in each server repo, which tells
SOPS which keys to encrypt each file to. No private key is ever placed in a
repository, in CI, in GitHub Actions secrets or on a Renovate runner.

**Rule:** retiring a key, or suspecting one has been exposed, means rotating
every secret it could decrypt, not only re-encrypting the files. Git history
keeps the old ciphertext, and the old key still opens it.

## Where the encrypted files live

**Decision 1 (made 2026-11-02): in each server repo.** The alternatives that
were weighed:

- **In each server repo (chosen).** The files sit beside the apps they
  configure, as `secrets/<app>.env.sops` and `secrets/root.env.sops`. The
  wrapper's signed-commit check already covers them, so no second trust path
  is needed. The cost is wider read access to the ciphertext: CI, Renovate
  and any session working in the repo can see it, though none can decrypt it.
- **In a separate private secrets repo.** Only the owner and the servers can
  read it. The cost is a second clone on each server, with its own deploy key
  and its own signature check in the wrapper. That is a second trust path to
  build, test and keep honest.

The second option would change only where step 2 of the deploy reads from,
so it remains open if the owner later wants a tighter circle of readers.

## Deploy flow

The wrapper (`vps-deploy`) runs as root and already verifies that `HEAD` is a
signed commit before doing anything else. Decryption is a new step after that
check and before `docker compose pull`:

1. Verify the signed commit (existing).
2. For each `secrets/*.sops` file, decrypt it with the server key into a
   temporary file. If the decrypted content differs from the current output,
   replace the output atomically. Unchanged files are left untouched, so their
   ctime does not move and AIDE stays quiet.
   - `secrets/root.env.sops` becomes `/opt/deploy/.env`.
   - `secrets/<app>.env.sops` becomes `apps/<app>/.env`.
3. If any file fails to decrypt, stop before touching any container and leave
   the existing outputs in place. A failed decrypt cannot take an app down.
4. Apply the existing guards to the outputs: mode `600`, and the refusal of
   `COMPOSE_*` variables.
5. Continue as today (`compose pull`, the app hooks, `compose up`).

The outputs stay gitignored and are owned by root. The deploy user no longer
writes them. That suits restricted mode, where the deploy user should not hold
secrets in the first place.

## Guards

- **CI:** a `check-secrets-encrypted.sh` job fails if any file under `secrets/`
  lacks SOPS metadata, or if any tracked `.env` file holds a value. It runs in
  `static-checks`, so it adds no minutes.
- **Pre-commit:** the same check runs as an optional hook for the owner's
  laptop.
- **Smoke test:** `post-provision-smoke-test.sh` checks that the server key
  exists with mode `0400`, that every `secrets/*.sops` file decrypts with it,
  and that no stray `.env.bak` or `*-env.bak-*` files remain.

## Phase 1: SOPS with the apps unchanged

1. **Scaffold** (`vps-base-template`):
   - an Ansible task that installs pinned `sops` and `age` binaries
     (checksum-verified) and creates the server key on first run;
   - the decrypt step in `vps-deploy.j2`;
   - the CI check, the smoke-test additions, and this document.
2. **Pilot on MCH:**
   - generate the keys and write `.sops.yaml`;
   - encrypt the current `.env` files, removing dead values (such as the
     Authelia leftovers) at the same time;
   - deploy, then confirm that the outputs match the previous files byte for
     byte, apart from the dead values;
   - run a rebuild drill from the repo and the recovery key alone.
3. **RCH**, then the other servers, after a week without incident on MCH.
4. **Clean-up:**
   - delete the `/root/*-env.bak-*` copies and the stray `.env.bak` files;
   - move the inventory (`ansible/hosts`) and the restic password into
     `secrets/recovery.sops` (Decision 2), then retire the recovery bundle
     and its smoke-test check;
   - retire the env-files backup once the drill has passed.

**Decision 2 (made 2026-11-02): the restic password and the inventory move
into SOPS.** Today the recovery bundle carries them. They move into
`secrets/recovery.sops`, encrypted to the owner and recovery keys only, not to
the server key: the server already holds the restic password in
`/etc/restic/`, and it never needs the inventory. A rebuild then needs only
the repo and the recovery key, and the recovery bundle is retired. The price
is the backup password living in git as ciphertext, under the key-retirement
rule above.

## Phase 2: Docker secrets for the valuable ones

Compose mounts each listed secret as a read-only file at `/run/secrets/<name>`
in only the containers that list it. Outside a swarm, Docker ignores the uid,
gid and mode options on a secret, so the file keeps its host owner and mode.
The decrypt step therefore writes each secret file owned by its container's
uid, mode `0400`, under `/run/vps-secrets/<app>/`. Two consequences follow:

- `/run` is memory, so decrypted secret files never reach the disk.
- `/run` is empty after a reboot. A `vps-secrets.service` unit, ordered
  before `docker.service`, decrypts at boot so that containers restarting
  under `restart: unless-stopped` find their files.

The secrets that move, in order of value:

| Secret | App | Support today |
|---|---|---|
| database passwords | Postgres containers | `POSTGRES_PASSWORD_FILE`, built in |
| `SESSION_SECRET` | gateway | needs `*_FILE` support (small change, our code) |
| `GITHUB_APP_PRIVATE_KEY_B64` | cms-auth | needs `*_FILE` support (small change, our code) |
| SMTP and AWS credentials | gateway, backup | gateway: our code; backup: root-run, reads files already |
| gateway shared secrets | Planka, cms-auth, Caddy | Planka: needs checking; Caddy: needs checking |

Third-party images are converted only where they read files natively. A
low-value secret stays in the environment rather than being worked around
with a custom entrypoint.

## What this does not protect against

- Root on a server can read that server's key and every secret in use. That is
  no change, since root could read them from the running containers anyway.
- Losing every private key loses the secrets. The recovery key exists to
  prevent that, and the rebuild drill proves it works.
- Until phase 2 reaches an app, its secrets remain visible to `docker inspect`
  and to its child processes, exactly as today.

## Effort

- Phase 1 scaffold work: about a day, including tests.
- Each server: about two hours, including the rebuild drill.
- Phase 2: about half a day for our own apps' `*_FILE` support, then an hour or
  so per app converted.
