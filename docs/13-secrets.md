# Secrets: SOPS-encrypted in git, Docker secrets at runtime

**Status (2026-11-02): phase 1 is built in the scaffold; no server has adopted
it yet.** The owner has made both decisions below. Phase 2 is not built.

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
2. Refuse any file under `secrets/` that git does not track. An untracked file
   is not part of the reviewed commit, so it is never decrypted.
3. Run `vps-secrets-render`, which decrypts every `secrets/**/*.sops` file
   with the server key. Each encrypted file mirrors the path of the file it
   becomes, with `.sops` appended:
   - `secrets/.env.sops` becomes `.env`;
   - `secrets/apps/<app>/.env.sops` becomes `apps/<app>/.env`;
   - `secrets/backup/services/<name>.env.sops` becomes
     `backup/services/<name>.env`.

   Only the env files that the wrapper already locks to `600` may be targets.
   `secrets/recovery.sops` is never rendered.
4. If any file fails to decrypt or validate, nothing is written and the deploy
   stops before touching any container. A failed decrypt cannot take an app
   down. A file whose content has not changed is left untouched, so its ctime
   does not move and AIDE stays quiet.
5. Continue as today (`compose pull`, the app hooks, `compose up`).

In default mode, `./deploy` runs the same render step through `sudo`, since
only root can read the server key. The automatic deploy always uses the root
wrapper.

The outputs stay gitignored and keep today's owner (the deploy user, mode
`600`), because default-mode deploys and some app hooks read them as that
user. The render step runs as root inside a checkout the deploy user owns, so
it never follows a symlink and creates each file with `O_EXCL | O_NOFOLLOW`
before renaming it into place. Root is never steered into writing elsewhere.
It also refuses decrypted content that sets a `COMPOSE_*` variable, as the
wrapper refuses such a `.env`.

## Guards

- **CI (built):** `scaffold/docker/check-secrets-encrypted.sh` fails if a file
  under `secrets/` is not SOPS-encrypted or holds an unencrypted value, if
  `secrets/` exists without `.sops.yaml`, or if git tracks a plain env file.
  A server repo adds it to `static-checks`, so it adds no minutes.
- **Tracked files only (built):** the wrapper refuses an untracked file under
  `secrets/`.
- **Pre-commit (not built):** the same check as an optional hook for the
  owner's laptop.
- **Smoke test (not built; server-repo layer):** `post-provision-smoke-test.sh`
  should check that the server key exists with mode `0400`, that
  `vps-secrets-render --check` passes, and that no stray `.env.bak` or
  `*-env.bak-*` files remain.

## Phase 1: SOPS with the apps unchanged

1. **Scaffold** (`vps-base-template`), built:
   - deploy-user role tasks that install `age` from the Ubuntu archive and the
     pinned, checksum-verified `sops` release, and create the server key on
     first run (printing its public half, also kept in
     `/etc/vps-scaffold/age/key.pub`);
   - `vps-secrets-render` and the decrypt step in `vps-deploy.j2` and
     `deploy.j2`;
   - the CI check and its tests, and this document.
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

## Adopting on a server

Plaintext never leaves the server during adoption. Encrypting needs only
public keys, so the server encrypts its own current files, and only
ciphertext travels to the laptop to be committed.

1. **Keys.** Bump the scaffold and run `site-quick`; it prints the server's
   public key, which is also kept in `/etc/vps-scaffold/age/key.pub`. On the
   laptop, `brew install sops age`, then create the owner key with
   `age-keygen -o ~/.config/sops/age/keys.txt` and set
   `SOPS_AGE_KEY_FILE` to that path in the shell profile. Create the recovery
   key with `age-keygen -o recovery-key.txt`, store the whole file in the
   password manager, note its public key, and delete the file. The owner and
   recovery keys are the same for every server.
2. **Recipients.** Commit `.sops.yaml` at the server repo root:

   ```yaml
   creation_rules:
     - path_regex: ^secrets/recovery\.sops$
       age: <owner public key>,<recovery public key>
     - path_regex: ^secrets/.*\.sops$
       age: <server public key>,<owner public key>,<recovery public key>
   ```

   Pull it on the server (`./deploy` or the next automatic deploy) before
   step 3, so the server encrypts to the same recipients.
3. **Encrypt on the server, outside the checkout.** The wrapper refuses
   untracked files under `secrets/`, so a deploy during adoption would stop if
   the ciphertext were written into the checkout. For each current env file,
   as root in `/opt/deploy`:

   ```bash
   f=apps/planka/.env
   out=/root/secrets-import/secrets/$f.sops
   mkdir -p "$(dirname "$out")"
   sops --encrypt --filename-override "secrets/$f.sops" \
     --input-type dotenv --output-type dotenv "$f" > "$out"
   ```

   `--filename-override` makes SOPS choose the recipients from `.sops.yaml`
   for the file's final path. Remove dead values first (edit the plaintext
   file, or decrypt, edit and re-encrypt afterwards). Copy
   `/root/secrets-import/secrets/` to the laptop (it is ciphertext), commit it
   signed into the server repo as `secrets/`, then delete
   `/root/secrets-import`.
4. **Check before the switch.** After the commit reaches the server, run
   `sudo vps-secrets-render --check`. Then compare each file without
   printing values; SOPS drops blank lines and ends the file with a newline,
   so the comparison ignores blank lines:

   ```bash
   for e in $(cd secrets && find . -name '*.sops' ! -name recovery.sops | sed 's#^\./##; s#\.sops$##'); do
     if cmp -s <(grep -v '^[[:space:]]*$' "$e") \
         <(SOPS_AGE_KEY_FILE=/etc/vps-scaffold/age/key.txt sops -d --input-type dotenv --output-type dotenv "secrets/$e.sops" | grep -v '^[[:space:]]*$'); then
       echo "same: $e"; else echo "DIFFERENT: $e"; fi
   done
   ```

   Every line should read `same`, apart from files where dead values were
   removed on purpose.
5. **Switch.** Add `bash scaffold/docker/check-secrets-encrypted.sh` to the
   server repo's `static-checks`, then deploy. The first deploy reports each
   file as `written` (the blank-line normalisation); later deploys report
   `unchanged`.
6. **From then on,** change a secret with `sops secrets/apps/<app>/.env.sops`
   on the laptop, commit signed and push. Never edit `.env` on the server: the
   next deploy overwrites it.

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
