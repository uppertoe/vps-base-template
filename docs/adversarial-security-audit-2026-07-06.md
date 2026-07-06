# Adversarial Security Audit — 2026-07-06

Five-lens parallel audit of both repos (Ansible hardening, container runtime,
secrets hygiene, CI/CD supply chain, compliance-claims-vs-code), with every
top finding re-verified against the source. Framing: defensibility under
Victorian health-service scrutiny (HPP 4 security, HPP 9 jurisdiction).

This record is the *starting* state. Items are struck through as they land.

## Verdict

Strong engineering and an unusually honest compliance pack, with one **critical
false claim**, one **architectural theme** (anything on `main` runs as root on
the box), and a cluster of **template-default vs paperwork** gaps. The history
sweep found **zero credentials ever committed** across 336 commits — the single
strongest defensibility fact.

## Findings (ranked by defensibility impact)

### CRITICAL
1. **"Backups Object-Locked / append-only" is false** (matrix row 16, SSP,
   docs/09, docs/11). `aws-backup-setup.py` never enables Object Lock; the
   on-box IAM key holds `s3:DeleteObject`; `backup.sh` runs `restic forget
   --prune`. On-box credential compromise can delete/overwrite backups. The
   **log** bucket genuinely is Object-Locked; the claim was transplanted to the
   backup bucket. → Fixed by truthful rewording (docs/09, docs/11, pack);
   architecture option (prune off-box / copy-to-locked-bucket) left as a
   design decision.

### HIGH — "anything on `main` = root on the box"
2. App deploy hooks (`apps/*/deploy.sh`) run **as root** via `vps-deploy`, fired
   unattended by `auto-deploy` on every upstream commit, with no signature
   check.
3. The runtime compose audit (`check-compose-hardening.py`) never inspects
   volume mounts or `cap_add` — a `docker.sock`/`/` bind or re-added
   `SYS_ADMIN` scores a clean PASS. The guardrail is blind to the exact escape.
4. `require_code_owner_reviews=false` on both repos — `renovate.json` and
   `deploy.sh` are not actually owner-protected. (Solo-repo: correct fix is
   doc-truth, not enabling the setting, which would deadlock merges.)
5. Restricted mode nullified by default: `deploy_admin_public_key` defaults to
   the deploy user's own key, and admin has `NOPASSWD:ALL` → one key = root.

### HIGH — secrets hygiene
6. Base-template `.gitignore` uses bash extglob
   (`ansible/inventory/!(production.example)`) which gitignore ignores — the
   inventory file the docs tell users to create (with tokens) is committable.
   (No credentials were ever actually committed — this is a latent footgun.)

### MEDIUM — template default vs paperwork
7. `log_export`, all ntfy alerting, immutable auditd, and restricted mode
   no-op with only a warning if an inventory line is omitted (unlike the
   deadman's hard `fail:`). A new instance inherits the pack's ✅ while
   shipping none of the control.
8. Real IP/provider/hostname + personal monitor domain in public git history
   (no creds). No gitleaks guard in CI. Recovery-bundle script defaults output
   into the repo, not gitignored. Zero `no_log` (secrets print under `--diff`).

### LOW — doc credibility nits
9. Evidence command `--tag env-files` returns nothing (tag is
   `env-files-files`); "48h SLA" the 3-day cooldown can't meet; auth
   `auth_data` volume "backed up" when only `.env` is; unfilled `⟨MFA type⟩` in
   a reviewed doc; jurisdiction record leaves AU-region blanks where the true
   answer helps HPP 9.

## Verified-strong controls (defensibility ledger)

No secrets in git history; forward_auth header-stripping regression-tested;
every image + action digest/SHA-pinned with Renovate refresh; force-push and
deletion blocked; secret scanning + push protection on; no
`pull_request_target`; firewall default-deny in/out; hash-chained logs to an
Object-Locked bucket; deadman mandatory by provisioning; encrypted swap,
immutable auditd (on L2 hosts), AIDE-in-check-mode → ntfy; quarterly access
review with a real cron-issue reminder.

## Remediation status (PRs in flight 2026-07-06)

- [x] Object-Lock claim corrected here (docs/09, docs/11); compliance pack in
      instance-repo PR
- [ ] `.gitignore` extglob fixed
- [ ] `no_log` on secret-templating tasks; gitleaks CI; recovery-bundle gitignore
- [ ] compose audit: mount / cap_add / host-network checks
- [ ] deploy-to-root: hooks-as-deploy, signature gate, distinct admin key,
      opt-in `fail:` gates
- [ ] **Decision pending:** Object-Lock *architecture* (prune off-box) vs
      accept versioned-recover posture as documented
