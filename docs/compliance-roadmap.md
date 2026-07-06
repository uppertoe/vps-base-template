# Compliance hardening roadmap

Planned scaffold changes that turn per-deployment compliance gaps into reusable,
secure-by-default capabilities every instance inherits. Derived from auditing a
live deployment (`prod-rch-vps`, 2026-06-23) against the controls common to
**ACSC Essential Eight, ISO/IEC 27001, and AU health-data regimes (VPDSS, the
Vic Health Records Act HPP 4)** — but written generically, since the scaffold
serves all VPS work and the *binding* framework is chosen per deployment.

**Philosophy:** the scaffold already does the hard host/Docker hardening (CIS L2,
auditd immutable, AIDE, real-time audit→ntfy, key-only SSH, ufw, TLS, deny-all).
The gaps below are mostly *data-protection*, *log-survivability*, and
*supply-chain* controls — the seams the single-box self-hosted model exposes.
Each item names the role/file to change and a default posture (prefer
secure-by-default; opt-in only where a destination/secret is required).

Priority: **P0** structural (a reviewer presses hardest, hardest to retrofit) ·
**P1** quick config/CI wins · **P2** enhancements.

> **Status (2026-07-02):** shipped — P1-1 (digest pins + `image-pins` CI gate in
> the server template), P1-2 (`audit-vuln.yml` + daily `vuln-scan.timer` +
> `pending-security-updates.timer`), P1-3 (admin TOTP default-on), P1-4
> (`restore-drill.timer` with RPO/RTO reports), P1-5 (`vps-deadman.timer`),
> P2-2 (`audit-all.yml` bundle + `docs/templates/`), the P0-1 encrypted-swap
> slice (`host_swap_encrypted`, default on), and the P0-2 Tier-1 path
> (`log-export` role: hash-chained nightly export to an Object-Locked bucket).
> The Victorian-health binding of this roadmap, plus the governance artifacts
> it doesn't cover, live in
> [compliance-plan-vic-health.md](compliance-plan-vic-health.md) (templates in
> [templates/](templates/)). Open: P0-1 volumes/FDE, P0-2 real-time SIEM
> forwarding (Tier 2), P2-1 container egress control.

---

## P0-1 · Encryption at rest
**Driver:** VPDSS, HPP 4, E8 (data protection) · **Current:** ❌ root, swap, and
all DB volumes are plain ext4 — no LUKS. Provision-time, so unfixable in place.

**Scaffold changes**
- **Encrypted swap (retrofittable, ship by default):** in `os-hardening`, replace
  the plain swapfile/partition with a **random-key encrypted swap** via
  `/etc/crypttab` (`swap … /dev/urandom swap,cipher=aes-xts-plain64`), or switch
  to `zram`. Closes the "secrets/PII leak into swap" hole today. Add
  `host_swap_encrypted: true` default.
- **Encrypted data volumes (opt-in):** a `docker`/`backup`-role option to place
  app/DB volumes on a LUKS-on-loopback or `gocryptfs` mount, unlocked at boot
  from a key in `/etc/cryptsetup-keys.d` (root-only). Var `host_encrypt_data_dir`.
- **Full-disk encryption (provisioning path, documented):** LUKS root with
  **remote unlock** (`dropbear-initramfs`) or Clevis+Tang/TPM. This is
  provider/image-dependent — provide a `bootstrap.yml` path where the provider
  supports it, otherwise **document** the rebuild procedure + provider
  encrypted-volume tiers. Don't pretend the scaffold can retrofit it.

**Effort:** swap = Low · volumes = Med · FDE = High (rebuild).

---

## P0-2 · Off-host, tamper-evident logging
**Driver:** VPDSS, ISM, ISO A.8.15 · **Current:** ❌ logs local only (journald
300 MB cap); a root compromise can erase the audit trail.

**Scaffold change**
- Extend the `os-hardening` rsyslog handling to support **secure remote
  forwarding**: `rsyslog omfwd` over **TLS** (RELP for reliability) to a
  configurable collector/SIEM. Forward at least auditd + auth + the
  `audit-notify` events. Var `log_forward_target` (host:port) + CA/cert vars;
  **opt-in** (needs a destination) but first-class and documented.
- Complements the existing real-time `audit→ntfy` bridge (alerting) with
  off-host **retention/forensics** (survives the box).

**Effort:** Medium (needs a destination — ideally the org SIEM).

---

## P1-1 · Image digest pinning (supply chain)
**Driver:** E8 #1–2, ISM · **Current:** ⚠️ `:latest` on auth/ntfy/authelia/postgres.

**Scaffold changes**
- Set `pinDigests` in the scaffold + template `renovate.json5`, and pin the
  scaffold-owned images (`vps-scaffold-auth`, `ntfy`) to digests by default.
- Add a **CI lint** (in `ci.yml`/`compliance-audits.yml`) that fails on an
  unpinned `:latest` for any security-critical image.

**Effort:** Low.

---

## P1-2 · Container/image vulnerability scanning
**Driver:** E8, ISM, ISO A.8.8 · **Current:** ❌ none — CIS scans *config*, not CVEs.

**Scaffold change**
- New `audit-vuln.yml` playbook running **Trivy** (or Grype) over the running
  images → `reports/vuln-<host>-<date>/`, plus a CI job. Fail/alert on
  CRITICAL/HIGH with available fixes. Wire criticals to `vps-notify`.

**Effort:** Low–Med.

---

## P1-3 · MFA on the application tier
**Driver:** E8 #3 · **Current:** ⚠️ SSH key-only (strong); Authelia `one_factor`,
auth gateway email-OTP (single factor) for app/clinical access.

**Scaffold changes**
- Make Authelia **`two_factor`** (TOTP/WebAuthn) the documented default for
  `protected_*` guards on sensitive resources; ship a 2FA-ready config.
- Confirm/extend `vps-scaffold-auth` to offer a second factor, or document
  key-only-SSH-as-admin-MFA + email-OTP-as-one-factor clearly in `05-access-model.md`.

**Effort:** Low–Med (mostly config + docs).

---

## P1-4 · Backup restore drill (DR evidence)
**Driver:** VPDSS, HPP, business continuity · **Current:** ⚠️ restic + verify run;
no *restore* evidence.

**Scaffold change**
- A `restore-drill` path in the `backup` role (`restore.sh` already exists):
  restore the latest snapshot into a throwaway target, assert integrity, tear
  down, and record **RPO/RTO achieved** to `reports/`. Optional periodic timer.

**Effort:** Low.

---

## P1-5 · External dead-man's-switch (host-down)
**Driver:** VPDSS BC, availability · **Current:** ❌ on-box ntfy can't alert when
the box itself is down (documented limitation in `apps/ntfy/README.md`).

**Scaffold change**
- Ship a small `notify`-role timer that curls an external monitor
  (Healthchecks.io / UptimeRobot) on a schedule. Var `deadman_switch_url`;
  opt-in but first-class. Closes the one hole the self-hosted alerting model
  otherwise has.

**Effort:** Low.

---

## P2-1 · Egress / application control
**Driver:** E8 #5 · **Current:** ⚠️ partial — AppArmor enforce, read-only rootfs,
no-new-privileges, pinned images already constrain execution.

**Scaffold change**
- Optional **default-deny egress** (ufw/`DOCKER-USER` outbound rules + per-app
  allowlist) so a compromised container can't exfiltrate/callback freely.
  Document the container-image-allowlist as the app-control story.

**Effort:** Med.

---

## P2-2 · One-command compliance evidence bundle
**Driver:** all (handover efficiency) · **Current:** ⚠️ audit playbooks exist but
are run individually; OpenSCAP defaults to L1.

**Scaffold changes**
- `audit-all.yml` orchestrator: run OpenSCAP (**L2 by default for this profile**),
  docker-bench, audit-compose, audit-vuln, Lynis → a single dated
  `reports/<host>-<date>/` bundle with an index.
- Generalise the deployment's `compliance/README.md` into a scaffold
  `docs/compliance-handover-template.md` so every instance ships a handover skeleton.

**Effort:** Low–Med.

---

## Sequencing

1. **Now (P1 quick wins):** digest pinning (P1-1), dead-man's-switch (P1-5),
   restore drill (P1-4), vuln scan (P1-2). Low effort, fold straight into
   existing roles/CI.
2. **Next (config):** Authelia 2FA (P1-3), encrypted swap (the P0-1 retrofit
   slice).
3. **Structural decisions (P0):** off-host logging destination (P0-2) and
   full-disk encryption (P0-1) — these need an external dependency (SIEM /
   provider FDE) and the FDE one is a rebuild, so decide before the next provision.
4. **Then:** evidence bundle (P2-2), egress control (P2-1).

> Keep the [exceptions register](08-security-model.md#exceptions-register) and the
> per-deployment `compliance/` handover in lock-step as these land.
