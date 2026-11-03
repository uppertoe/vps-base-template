# 15 — The release tree

Status: design, 2026-11-03. Owner decisions recorded in §2. Implementation
lands behind `deploy_release_tree` (default `false`) and is adopted one server
at a time, RCH first.

## 1. The weakness this closes

Today `/opt/deploy` is a git checkout owned by the deploy account. `vps-deploy`
runs as root and checks that checkout carefully (clean tree against a private
index copy, branch and upstream, the scaffold pointer, untracked hooks, the
signature on HEAD), then executes what is in it: compose files, Caddy
snippets, app hooks and the rendered secrets. Between the moment root checks a
file and the moment root uses it, the deploy account can still write to it. In
restricted mode the deploy account is meant to be unable to act as root, so
that window is a privilege boundary with a hole in it (the time-of-check,
time-of-use note in docs/13-secrets.md §6).

The cure is for root to use only files the deploy account cannot write: root
fetches the repository itself, verifies the commit itself, and exports that
commit into a tree it owns. Nothing the deploy account can touch is consulted
or executed.

## 2. Decisions (owner, 2026-11-02 and 2026-11-03)

1. Root owns git state for the release path. This lifts the 2026-10-31 rule
   that root must not own git state: that rule existed because root and the
   deploy account shared one repository, and the mixed ownership broke deploys.
   In this design the two never share a repository.
2. Releases are versioned. Each deploy exports into
   `/opt/deploy-releases/<commit>`, and `/opt/deploy` becomes a symlink that is
   switched to the new release in one rename. A deploy cannot leave a
   half-updated tree, and rollback is switching the link back.
3. Nothing is hand-placed inside a release. Files that today live untracked in
   `/opt/deploy` move to SOPS (secrets), a Docker volume (anything a container
   writes) or out of the deploy path altogether. On markbot this means
   Authelia's signing key and user list go into SOPS and its writable
   configuration folder becomes a volume.

## 3. How a deploy runs

All steps run as root, one deploy at a time (a lock in `vps-deploy` and
another in `vps-release`), under `env -i` with no system or global git
configuration or attributes, hooks disabled, replacement objects ignored,
objects checked on fetch, and only the `https` and `ssh` transports allowed.
A failed fetch fails the deploy; it never falls back to the cached tip.

1. **Fetch.** `/var/lib/vps-deploy/repo.git` is a root-owned bare mirror of
   the server repo. Root fetches `origin/<deploy_branch>` into it with the
   read-only deploy key at `/etc/vps-scaffold/deploy-key` (root, 0600) and a
   pinned `known_hosts`, never the deploy account's SSH configuration.
2. **Choose the commit.** The commit to deploy is the fetched tip, never a
   name the deploy account can influence.
3. **Verify.** The signature check of today's `vps-deploy` runs against the
   mirror, with the same root-owned trust stores (`/etc/ssh/allowed_signers`,
   `/etc/vps-scaffold/gnupg`).
4. **Fetch the scaffold.** The scaffold commit is the gitlink recorded in the
   verified commit. Root fetches it into `/var/lib/vps-deploy/scaffold.git`
   from the URL in that commit's `.gitmodules`, which must be `https://`.
5. **Export.** `git archive` of the verified commit, and of the recorded
   scaffold commit into `scaffold/`, unpacks into
   `/opt/deploy-releases/.<commit>.partial`. Every file is root-owned, files
   0644 and executables 0755 exactly as git records them, directories 0755.
   A file git marks as a symlink is refused if it points outside the release.
6. **Render secrets.** `vps-secrets-render --repo <release>` decrypts
   `secrets/**/*.sops` into the release, root-owned, 0600.
7. **Switch.** The partial directory is renamed to its final name, a new
   symlink is created beside `/opt/deploy` and renamed over it, and the switch
   is appended to `/var/lib/vps-deploy/history`. `vps-deploy` and the app
   wrappers set `COMPOSE_PROJECT_NAME=deploy`, so the project name and the
   container names do not change. Anything else that runs Compose against
   `/opt/deploy` should do the same, or the server repo's compose file should
   carry a top-level `name: deploy`: without either, a caller with no `PWD`
   names the project after the release directory.
8. **Run.** Images are pulled before the switch, so an unreachable registry
   fails the deploy with the running release in place. App hooks and `docker
   compose up --wait` then run, as today, from `/opt/deploy`. The first
   switch from a checkout recreates every container once, so none keeps a
   mount opened in the old checkout; later deploys recreate only the services
   whose settings or mounted files changed (docs/04).
   App hooks run as root from the release and must not write inside it; a
   release never changes after its export.
9. **Keep three.** The current release and the two most recently deployed
   before it are kept for rollback; older ones are removed.

If any step before the switch fails, `/opt/deploy` still points at the
previous release and nothing has been restarted.

## 4. Rollback

`sudo vps-deploy --rollback` switches `/opt/deploy` to the release deployed
before the current one (from the switch history) and runs step 8. It does
not fetch, so it works with GitHub unreachable, but it verifies the kept
release's signature again in case a signer has been removed since. The
commit rolled back from is then held: auto-deploy skips it until a new
commit reaches the branch, so the rollback is not undone within minutes. A
rollback is announced over ntfy, and any ordinary deploy clears the hold. The hold is re-checked under the deploy lock, so a
rollback that finishes while auto-deploy is waiting is not undone. A second
`--rollback` returns to the release just rolled back from; to go further
back, deploy an earlier commit through git instead. A rollback recreates
the services whose settings differ between the two releases, so a rollback
that changes an app's settings carries the same risk as a deploy that does:
check before running it
on an app whose key change is irreversible (p.stonn's `DATA_ENCRYPTION_KEY`).

## 5. What changes for people

- `~/deploy` (both modes) runs `sudo vps-deploy`. In default mode the deploy
  account keeps its broad sudo, so this changes nothing about who can deploy.
- The deploy account no longer has a checkout to pull into. The old checkout
  is renamed to `/opt/deploy-legacy` at the first switch and removed by hand
  once the server has deployed cleanly from releases. Until then it still
  holds the old plaintext `.env` files.
- Root's Docker configuration holds only the registry logins taken from the
  deploy account's `~/.docker/config.json`, never the rest of that file
  (credential helpers, proxies and plugin directories would otherwise choose
  what root's `docker` runs).
- `vps-git <args>` reads the root mirror (`git --git-dir
  /var/lib/vps-deploy/repo.git`), so `vps-git log --oneline -5` still works.
  `vps-git-heal` does nothing once `/opt/deploy` is a link, because no
  repository is shared.
- `auto-deploy` compares the mirror's fetched tip with the commit
  `/opt/deploy` points at, rather than a checkout's `HEAD` with `@{u}`.
- `scaffold-drift-check` reads the scaffold commit from the current release's
  `.release` file (commit, scaffold commit, time) and compares it with
  upstream through root's scaffold mirror (`vps-release scaffold-behind`).
- AIDE's existing `/opt/deploy DeployConf` rule also covers
  `/opt/deploy-releases`, because selection lines are prefix regexes. A
  release never changes after its export, so any change inside one alerts;
  every release deploy rebaselines. Root's mirrors under `/var/lib/vps-deploy`
  are excluded, as `.git` was.

## 6. Migration on an existing server

Behind `deploy_release_tree: true` in the inventory, then a site play:

1. The role checks the running stack (step 3 below) before anything else, then
   copies the deploy key to `/etc/vps-scaffold/deploy-key`, pins GitHub's host
   key and installs `vps-release`. In restricted mode it takes the repo URL
   only from `deploy_repo_url` in the inventory, never from the deploy
   account's checkout, and requires `deploy_verify_signature: true`.
2. The first deploy exports the current tip, renders the secrets and switches.
   Because `/opt/deploy` is a directory, not yet a link, this first switch
   renames it to `/opt/deploy-legacy`, then creates the link. Volumes, image
   cache and container state are unaffected; containers are recreated by the
   deploy as usual.
3. Before that first deploy, every untracked file the running stack reads
   from `/opt/deploy` must have a new home (§2.3). The play, and `vps-release`
   again at the first switch, refuse while a running container binds a path
   under `/opt/deploy` that git does not track or that the container writes
   to. The first switch also refuses while an env file in the checkout has no
   rendered counterpart in the release.
4. `/opt/deploy-legacy` is removed by hand once the server has deployed
   cleanly from releases.
5. The change is one-way: the play refuses `deploy_release_tree: false` once
   `/opt/deploy` is a release link.

## 7. Things this does not change

- The deploy key stays read-only, and root's copy is the only one in use.
- CI, Renovate, auto-merge and the ntfy deploy trigger are unchanged.
- The secrets design (docs/13) is unchanged, apart from rendering into a
  release instead of a checkout.

## 8. Testing

`ansible/roles/deploy-user/files/test_vps_release.sh` runs `vps-release`
end to end in a throwaway Ubuntu container against the public
server-instance-template: fetch, export with the scaffold, ownership and
modes, the first switch from a checkout, previous, prune, switching back and
the symlink rule. It needs network access, so it is run by hand:

```bash
cd ansible/roles/deploy-user/files
docker run --rm -v "$PWD":/t:ro ubuntu:24.04 bash /t/test_vps_release.sh
```

## 9. Open items

- Git LFS is not supported: a release would contain LFS pointer files.
- `transfer.fsckObjects` refuses malformed objects on fetch. A server repo
  whose old history carries fsck warnings needs `fetch.fsck.<msg-id>=ignore`
  for that warning, not the check turned off.

- markbot needs SOPS support for two non-dotenv files (Authelia's key and
  user list) before it can adopt; `vps-secrets-render` gains a binary mode
  for `secrets/**/*.file.sops`.
- `provision.sh`, `restore.sh` and the post-provision smoke test assume a
  checkout at `/opt/deploy` and need a release-tree path.
