# LTS Migration — Moving Instances to the Next Ubuntu Release

The migration is a **blue-green rebuild, never `do-release-upgrade`**. The
scaffold's evidence model is "a fresh provision is what CI tested" — an
in-place-upgraded box is a configuration state no CI run has ever seen, and
the hardening stack (immutable auditd rules, AIDE baselines, devsec sysctls,
AppArmor, pinned apt repos) fights release upgrades on a 2 GB host anyway.
Each instance migrates by walking [09-recovery.md](09-recovery.md)'s rebuild
drill against a fresh VPS on the new release; the migration doubles as that
year's drill, so log the RTO.

Watch the "OS lifetime" tile on the evidence dashboard: it turns amber with a
year of standard support left. Do not start at the crunch — the gates below
lag a new release by months, so begin roughly when the first point release
(`.1`) of the new LTS lands.

## Phase gates (do not migrate past a red gate)

The audit layer is release-specific. Before any instance moves:

- [ ] **CIS Benchmark** published for the new release (no benchmark → no L2
      claim → the compliance evidence goes dark).
- [ ] **ComplianceAsCode** ships a product/datastream for the new release
      (24.04 already required building from upstream CaC — expect the same).
- [ ] **devsec os-hardening** supports the release.
- [ ] Canonical has opened the upgrade path (the `.1` point release).

## Phase 1 — scaffold enablement (paid once, in this repo)

On a branch in `vps-base-template`:

1. Switch Molecule platforms and the CI provisioning workflow to the new
   release; drive the whole pipeline green. Expect deltas in sshd defaults,
   systemd behavior, and renamed/dropped packages.
2. Rebuild the OpenSCAP datastream for the new release; re-derive the
   tailoring file (rule IDs change between releases) and re-adjudicate every
   entry in the exceptions register against the new benchmark.
3. Sweep hardcoded release references in BOTH repos —
   `grep -ri '24\.04\|noble' --exclude-dir=.git .` — expected hits: docs
   (01/03/08), CI workflow images, Molecule platform images,
   `scripts/render-compliance-pages.sh` (the `OS_EOL_DATE` constant),
   `.github/workflows/maintenance-day.yml` (EOL text), `ansible/hosts.example`.
4. Optionally run CI as a matrix over both releases while instances straddle
   the transition.

## Phase 2 — canary soak

One throwaway VPS on the new release, provisioned from the updated scaffold:
`site-first-run.yml`, deploy the stack, `audit-all.yml`, then let it sit for
a few weeks. The watchers are the soak test — a quiet ntfy channel plus a
passing monthly self-test IS the evidence the release runs unattended.

## Phase 3 — per-instance migration (repeat per VPS repo)

1. Refresh the recovery bundle (`scripts/make-recovery-bundle.sh`); lower the
   DNS TTL a day ahead.
2. Provision a fresh VPS on the new release from the SAME instance repo (new
   IP in the inventory), with the scaffold pointer bumped to the enabled
   commit: `bootstrap.yml` → `site-first-run.yml` → `./deploy`.
3. Data cutover: quiesce writes on the old box → final backup run → restic
   restore into the new box's volumes → verify.
4. Repoint the dead-man's switch and ntfy subscriptions at the NEW box
   *before* cutover, so the box serving traffic is the one being watched.
5. Smoke test + `audit-all.yml` on the new box, then cut DNS.
6. Keep the old box powered but out of rotation for a week as rollback, then
   destroy it. Record the wall-clock time in 09-recovery.md's RTO log.

## Phase 4 — retire the old release

Once every instance has moved: drop the old release from CI, update docs/03,
and close the loop on the maintenance-day issue that has been nagging about
the EOL countdown.
