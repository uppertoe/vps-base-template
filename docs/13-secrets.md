# Secrets: SOPS-encrypted in git, Docker secrets at runtime

**Status (2026-11-04): phase 1 is built and in use on MCH, RCH and markbot.**
The owner has made both decisions below. Phase 2 is not built.

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

   Only the env files that the wrapper already locks to `600` may be targets,
   plus the whole files described under "Whole files" below.
   `secrets/recovery.sops` is never rendered. When the repo carries
   `secrets/backup/config.env.sops`, the renderer also installs the rendered
   backup set into `/etc/restic` (root-only, `--restic-dir`) and removes a
   service file there that the repo no longer names, so the reviewed commit
   is the only source of the restic configuration.
4. If any file fails to decrypt or validate, nothing is written and the deploy
   stops before touching any container. A failed decrypt cannot take an app
   down. A file whose content has not changed is left untouched, so its ctime
   does not move and AIDE stays quiet.
5. Continue as today (`compose pull`, the app hooks, `compose up`).

In default mode, `./deploy` runs the same render step through `sudo`, since
only root can read the server key. The automatic deploy always uses the root
wrapper.

The outputs stay gitignored. In checkout mode they keep the deploy user as
owner, mode `600`, because default-mode deploys and some app hooks read them
as that user; under the release tree (docs/15) `vps-release` renders them
root-owned, mode `600`, inside the release. In checkout mode the server key
therefore protects nothing the deploy user cannot already read once rendered;
never encrypt a root-only secret to it.

The render step runs as root inside a checkout the deploy user owns. In
restricted mode that user is not root-equivalent, so the step is built not to
let them write, read or hang anything they could not already
(`vps-secrets-render` lists every rule):

- Encrypted files are read through directory handles that never follow a link
  or block on a FIFO, and handed to sops on stdin. sops never opens a path the
  deploy user could swap for a link to the server key.
- sops runs in an empty root-owned directory with an empty `HOME`, with age as
  its only method, and a file naming any other key source (KMS, Vault, PGP and
  so on) is refused before sops sees it.
- sops' own error messages are never shown, because for a malformed file they
  quote the offending line.
- New files are created under a `.env.` temporary name with
  `O_EXCL | O_NOFOLLOW` and renamed into place; stale temporary files from an
  interrupted run are removed first.
- Decrypted dotenv content that sets a `COMPOSE_*` variable or holds a
  carriage return is refused.

## Whole files

Some secrets are not environment variables: Authelia's OIDC signing key and
its user list on markbot are files that the container reads from a mount. A
secrets file whose name does not end in `.env.sops` is a whole file. It is
encrypted with sops' binary type and rendered byte for byte to its mirrored
path, mode `0600`, owned like every rendered file:

```text
secrets/apps/authelia/config/oidc.pem.sops           -> apps/authelia/config/oidc.pem
secrets/apps/authelia/config/users_database.yml.sops -> apps/authelia/config/users_database.yml
```

Four rules apply to a whole file and not to a dotenv file:

- Its rendered path must lie below a subdirectory of an app
  (`apps/<app>/<dir>/.../<file>`). The deploy reads compose files, hooks and
  Caddy snippets from an app's top level, so nothing rendered is ever
  executed or assembled by the deploy itself.
- Its rendered path must not be a file git tracks. The CI check, the wrapper
  and `vps-release` all refuse a secrets file that would replace a reviewed
  file with content no reviewer can read.
- The dotenv checks (the `COMPOSE_*` guard, the carriage-return refusal) do
  not apply; an empty result is refused as a mistake.
- The renderer records the whole files it has written under
  `/var/lib/vps-secrets-render/` (root-only) and removes one whose secrets file
  has since left the repo, so a retired key or user list does not stay in use.
  A dotenv file is not removed: compose reads it by name from the tracked
  compose files, and the wrapper locks the whole set.

The permission pass that makes bind-mounted repo files world-readable skips
the rendered whole files, which stay `0600`. The container must therefore run
as the owner of the rendered files: the deploy account in checkout mode, root
under the release tree. An app whose container runs as another uid cannot
read a whole file rendered this way until phase 2 writes secret files under
`/run/vps-secrets/<app>/` owned by the container's uid.

Encrypt a whole file on the server, outside the checkout, as for a dotenv
file, with the binary type and the final path named so that `.sops.yaml`
picks the recipients:

```bash
f=apps/authelia/config/oidc.pem
out=/root/secrets-import/secrets/$f.sops
mkdir -p "$(dirname "$out")"
sops --encrypt --filename-override "secrets/$f.sops" \
  --input-type binary --output-type binary "$f" > "$out"
```

The result is a small JSON document whose one `data` value is the encrypted
file; `sops secrets/$f.sops` on the laptop opens it for editing as usual. The
CI check accepts exactly that document, with age as its only key source.

## Guards

- **CI (built):** `scaffold/docker/check-secrets-encrypted.sh` fails if a
  dotenv file under `secrets/` is not SOPS-encrypted with every line
  encrypted, empty or SOPS' age metadata, if a whole file is not the binary
  document sops writes, sits anywhere but below an app's subdirectory, or
  would be rendered over a tracked file, if `secrets/` exists without
  `.sops.yaml`, or if git tracks a plain env file (`.env`, `*.env`, `.env.*`).
  A server repo turns it on with `secrets_sops: true` in its
  `.scaffold-server.yml`; the shared CI (docs/14) then runs the check in its
  static checks, so it adds no minutes. The server's `ci.yml` is a canonical
  copy and is not edited directly.
- **Tracked files only (built):** the wrapper refuses an untracked file under
  `secrets/`.
- **Pre-commit (not built):** the same check as an optional hook for the
  owner's laptop.
- **Smoke test (built in part):** `post-provision-smoke-test.sh` reports the
  recovery set as held in SOPS when `secrets/recovery.sops` exists, and
  checks that `/etc/restic` matches `secrets/backup/`. Still to build: that
  the server key exists with mode `0400`, that `vps-secrets-render --check`
  passes, and that no stray `.env.bak` or `*-env.bak-*` files remain.

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
   - move the inventory (`ansible/hosts`) into `secrets/recovery.sops` and
     the restic configuration into `secrets/backup/` (Decision 2); the
     recovery bundle and its smoke-test check then retire themselves
     (done 2026-11-03: the smoke test, `provision.sh`,
     `make-recovery-bundle.sh` and `restore.sh --from-sops` all recognise a
     repo that carries `secrets/recovery.sops`);
   - retire the env-files backup once the drill has passed.

**Decision 2 (made 2026-11-02, layout settled 2026-11-03): the restic
configuration and the inventory move into SOPS.** The recovery bundle used to
carry them. The inventory moves into `secrets/recovery.sops` (dotenv, like
every secrets file; the inventory is one base64 value, `ANSIBLE_HOSTS_B64`),
encrypted to the owner and recovery keys only, not to the server key, which
never needs it. The restic configuration (`config.env` and
`services/*.env`) moves into `secrets/backup/`, encrypted to the server key
as well, because the renderer installs it into `/etc/restic` at every deploy;
the repo is then the only source of what restic backs up, and a retired
service stops being backed up when its file leaves the repo. A rebuild then
needs only the repo and the recovery key, and the recovery bundle is retired.
The price is the backup password living in git as ciphertext, under the key-retirement
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
5. **Switch.** Set `secrets_sops: true` in the server repo's
   `.scaffold-server.yml`, so the shared CI runs
   `check-secrets-encrypted.sh`, then deploy. The first deploy reports each
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

- **A deploy-user race against the whole deploy, in the checkout layout.** The
  checkout-mode wrapper checks a checkout the deploy user can still write to,
  then uses it. A deploy user who edits the tree during a run gets past the
  clean-tree, tracked-file and signature checks: changing an app hook or a
  compose file after the checks already gives root execution, without any of
  this feature. The render step adds no new way through, because it reads each
  file once through no-follow handles. The release tree (docs/15) closes this
  window: root fetches, verifies and exports each commit into a tree the
  deploy account cannot write, and renders the secrets into it. Restricted
  mode requires the release tree for that reason, and both production servers
  run on it. On a server still in the checkout layout, the window remains.

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
