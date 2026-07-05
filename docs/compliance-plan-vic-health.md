# Victorian healthcare compliance plan

**Profile:** a scaffold-provisioned VPS hosting clinical/health-adjacent web apps used in a
Victorian public health service context.
**Drafted:** 2026-07-02, against sources current at that date (currency flags noted inline).
**Relationship to other docs:** this plan *binds* the generic
[compliance-roadmap.md](compliance-roadmap.md) items to the specific Victorian standards an
auditor will cite, adds the governance/evidence work the roadmap doesn't cover, and extends
the layered benchmark model in [08-security-model.md](08-security-model.md) with a
"regulatory" layer on top.

---

## 1. The standards that actually apply

### 1.1 Binding instruments (in order of authority)

1. **Health Records Act 2001 (Vic) — the HPPs** (authorised version No. 050, in force
   1 May 2026). Applies to *anyone* handling health information in Victoria, regardless of
   public/private status. The two principles a hosting platform must answer for:
   - **HPP 4 (Data Security & Retention):** "reasonable steps to protect the health
     information … from misuse and loss and from unauthorised access, modification or
     disclosure" (4.1) — this is the legal hook an auditor hangs the *entire technical
     control stack* on. Plus retention: health information must not be deleted before
     **7 years after last service, or age 25 for child-collected records, whichever is
     later** (4.2), with written deletion logs (4.3) and transfer logs (4.4).
   - **HPP 9 (Transborder Data Flows):** transferring health information to anyone
     **outside Victoria** (interstate counts, not just offshore) requires one of the
     9.1(a)–(g) grounds. Hosting on a VPS outside Victoria *is* a transfer. Interstate
     Australian hosting is trivially defensible via 9.1(a) (substantially similar law);
     offshore hosting needs a documented 9.1(f) "reasonable steps" position
     (contract + technical controls) and sits against OVIC guidance that flags
     foreign-owned providers' exposure to foreign law-enforcement access **even for data
     held in Australia** (the CLOUD Act problem).
   - Enforcement: Health Complaints Commissioner compliance notices (s 66; non-compliance
     is an indictable offence), VCAT compensation to $100k. No mandatory Victorian breach
     notification, but HCC encourages reporting within 14 days; Commonwealth NDB applies
     to private providers.

2. **DH Policy and Funding Guidelines §24 (2025-26)** — the operative cyber mandate for
   Victorian public health services (Victoria has no Health Service Directives; this is
   the funding instrument). Requires health services to: implement the **Health Sector
   Cybersecurity Maturity Framework** and the **Baseline Cybersecurity Controls**
   ("based on ASD Essential 8, CIS, and NIST CSF … the minimum security controls that
   public health services and community health centres must implement"); self-assess via
   the **VMIA Self-Assessment Hub** and accept directed audits; report to executive and
   board; **own third-party supplier cyber risk**; and report significant ICT incidents
   to the eHealth Incident Management Team **within the hour** (1300 598 686 /
   Digital.Health.Incident.Notification@health.vic.gov.au), with all cyber incidents
   (including supplier breaches) reported as soon as detected or suspected.
   > ⚠️ The Baseline Cybersecurity Controls workbook itself is distributed through the
   > VMIA hub, not published. **Action for the instance owner:** obtain the current
   > workbook through the health service's VMIA access and map it into the control
   > matrix (§4.2) — the historical baseline was 72 controls (38 foundational),
   > NIST-CSF-categorised, per VAGO 2019.

3. **VPDSS 2.0 (OVIC) — reference framework, usually not a direct duty.** The critical
   applicability fact: **PDP Act s 84(2)(d)–(g) excludes public hospitals, public health
   services, multi-purpose services and ambulance services from Part 4**, so VPDSS does
   not directly bind them. It *does* bind if the operator acts as a **contracted service
   provider to a covered body** (e.g. the Department of Health itself) via s 88(2) —
   in that case the SRPA/PDSP/attestation cycle applies (PDSP biennially in even years;
   the current submission window is **1 July – 31 August 2026**, no extensions).
   Either way, **VPDSS Standard 11 (ICT Security)** is the best-practice reference
   auditors borrow: E11.010 system security plan, E11.030 assess-and-authorise before
   go-live, E11.040 vulnerability/patch management, E11.090 hardening/SOE, E11.110
   logging & monitoring, E11.120 privileged administration, E11.130 segmentation,
   E11.140–150 cryptography/key management, E11.180 backups, E11.190 secure SDLC —
   each mapped by OVIC to ISM / Essential Eight / ISO 27002:2022 controls
   (Implementation Guidance V2.4, Jan 2026 — VPDSS is still v2.0; a rewrite has been
   flagged but not delivered). Standard 2 (asset register + Business Impact Levels)
   and Standard 8 (third-party arrangements) also travel contractually.

4. **Situational Commonwealth law:**
   - **My Health Records Act 2012 (Cth) s 77** — hard prohibition on holding/processing
     MHR-system data outside Australia; consent cannot override it. Only relevant if an
     app registers as an MHR portal/repository/CSP — **do not connect apps on this
     platform to MHR** without a dedicated onshore, ADHA-conformant build.
   - **SOCI CIRMP** — designated critical hospitals must hold E8 ML1 / ISO 27001 / NIST
     CSF (or equivalent) with annual board-approved reports. Only applies if the platform
     becomes part of a designated hospital's critical infrastructure.
   - **Cyber Security Act 2024** — ransomware payment reporting to ASD within 72h
     (entities >$3M turnover; enforced from 1 Jan 2026).

### 1.2 Technical benchmarks an auditor will test against

- **ACSC ISM (June 2026 release; quarterly cycle).** The controls that bite on this
  platform:
  - **ISM-1409** — OS hardened per ASD *and vendor* hardening guidance, most restrictive
    wins. For Ubuntu the vendor tooling (Canonical USG) *is* the CIS benchmark, so the
    scaffold's CIS-based model is the defensible reading. Cite this chain in the SSP.
  - **Patching SLAs** — internet-facing services and server OS: **48 hours** for
    critical/exploited vulnerabilities, **2 weeks** otherwise; 1 month for the rest;
    **daily vulnerability scanning** of internet-facing services (also E8 ML1).
  - **ISM-1988 / ISM-1815** — event logs retained **searchable ≥ 12 months**, protected
    from modification/deletion, centralised. Reinforced by the ASD-led *Best Practices
    for Event Logging and Threat Detection* (Aug 2024): structured (JSON) logs,
    consistent timestamps, TLS 1.3 in transit, off-host aggregation.
  - **ISM-1173** — MFA for all privileged users; ISM has no SSH-specific MFA control —
    key-only SSH (ISM-0484/0485), passphrase-protected keys (ISM-1449), IP-restricted
    automation (ISM-0487). The accepted pattern is MFA at the admin entry point plus
    key-based SSH.
  - **ISM-1269/1270/1271/1273/1277** — web/DB functional separation, DB on its own
    network segment with access controls, dev/prod segregation, approved crypto between
    tiers.
  - **ISM-1810/1811/1812/1814** — backups synchronised to a common point, retained
    securely/resiliently, inaccessible and unmodifiable by unprivileged accounts.
  - **Cryptography** — ASD-approved algorithms now; PQC transition plan expected by
    **end-2026**, RSA/ECDH/ECDSA retired by 2030 (ML-KEM-1024 / ML-DSA-87 era). A
    one-paragraph PQC posture statement in the SSP satisfies "plan" at this scale.
- **Essential Eight Maturity Model (Nov 2023 model — still current, verify at
  assessment time).** ASD's own FAQ says E8 targets Windows networks and directs Linux
  estates to *Hardening Linux workstations and servers* (Nov 2023) + ISM. So the audit
  posture is: **E8-equivalent implementation on Linux, evidenced through ISM/CIS
  controls** — application control → image allowlist + AppArmor + `noexec` mounts;
  patch apps/OS → unattended-upgrades + Trivy + SLA evidence; MFA → auth tier + admin
  entry; restrict admin → deploy/admin split + revalidation; backups → restic + drills.
  ML2 is the de-facto government/health target (PSPF mandates ML2 federally).
- **CIS Benchmarks.** Ubuntu 24.04: the catalogue moved to **v2.0.0 (June 2026)**; the
  scaffold measures against SSG's v1.0.0 profiles — keep v1.0.0 as the measurement of
  record until ComplianceAsCode ships v2.0.0-aligned profiles, and record that delta in
  the exceptions register. Docker: CIS Docker **v1.8.0** (mid-2025, Docker Engine 28);
  docker-bench-security still trails — same treatment.
- **VAGO precedent (what Victorian auditors actually probed).** *Cybersecurity: IT
  Servers* (Oct 2025): complete server inventory, OS on mainstream support, hardening
  baseline, patch cadence, EDR coverage, privileged access, tested backups. *Security of
  Patients' Hospital Data* (2019): baseline-72 controls, default credentials, stale
  accounts, admin MFA, third-party compliance. Design the evidence bundle to answer
  exactly these.

### 1.3 What this means for the scaffold

The scaffold's framework decision (docs/08: CIS as measurement of record, layered
verifiers) **survives contact with the Victorian stack** — nothing here demands replacing
CIS with something else. What the Victorian stack adds is:

1. a **governance/evidence layer** (SSP, asset register + BIL, HPP 4/9 narratives,
   incident response wired to DH's 1-hour clock, supplier-assessment answers) that no
   amount of hardening code substitutes for;
2. four **technical control gaps** with named control numbers behind them (at-rest
   encryption, 12-month off-host logs, MFA defaults, patch-SLA/scan cadence evidence); and
3. two **per-deployment decisions** (hosting jurisdiction; EDR posture) that must be made
   and documented per instance, not solved in the scaffold.

---

## 2. Current posture vs the audit stack

| Audit requirement (source) | Scaffold today | Verdict |
|---|---|---|
| OS hardened to vendor/ASD guidance (ISM-1409; VPDSS E11.090) | CIS L1 (opt-in L2) via devsec + baseline-hardening; OpenSCAP + tailoring file; exceptions register | ✅ strong — cite USG/CIS chain in SSP |
| Container/daemon hardening (CIS Docker) | §1–4 docker-bench, §5 audit-compose + KICS; digest-pinned caddy | ✅ (benchmark version refresh pending) |
| Key-only SSH, no root, protected keys (ISM-0484/0485/1449) | Enforced; root locked; single `deploy` user | ✅ |
| MFA for privileged users (ISM-1173; E8 ML2) | SSH key-only; auth tier email-OTP single factor; admin TOTP **off by default** | ⚠️ gap — WS-B4 |
| Admin privilege lifecycle (E8 ML2: 12-month revalidation, 45-day dormancy) | Single high-trust `deploy` account, no review cadence | ⚠️ document + WS-A6 |
| Patch SLAs 48h/2wk + daily scanning (ISM; E8 ML1) | unattended-upgrades + patch-window reboots + daily vuln-scan timer + PATCH-SLA journal | ✅ (WS-B2 shipped) |
| Logs searchable 12 months, off-host, tamper-protected (ISM-1988/1815) | log-export → write-only Object-Locked S3 ≥12 months; weekly digest = automated review | ✅ (WS-B3 shipped) |
| Encryption at rest (HPP 4 "reasonable steps"; VPDSS E11.140) | swap encrypted (random key/boot); root + data volumes still plain | ⚠️ WS-B1.2–3 (next provision) |
| Encryption in transit | Caddy auto-HTTPS/ACME; TLS everywhere externally | ✅ |
| Web/DB separation (ISM-1269/1270/1271) | Generated per-app proxy networks; compose-audit exclusivity + DB gates | ✅ (WS-B6 shipped) |
| Backups secure, restore-tested (ISM-1810–1814; E8) | restic + weekly check + restore-drill timer (RPO/RTO recorded) | ✅ (WS-B5 shipped) |
| Backup credentials can't delete history (ISM-1814) | S3 Object Lock + prefix-scoped IAM | ✅ |
| Data retention 7-year/age-25 + deletion logs (HPP 4.2–4.4) | Not addressed (app-level, but platform must not undermine it) | ⚠️ WS-A4 |
| Hosting jurisdiction + HPP 9 ground | Undocumented; provider-dependent | ❌ decision — WS-C1 |
| Incident response to DH 1-hour clock | docs/11 generic runbook + per-instance template w/ DH contacts; worked example in server-instance-template | ⚠️ per-instance contacts + annual test |
| Asset register + BIL (VPDSS Std 2; VAGO server inventory) | Worked example: server-instance-template `docs/compliance-pack/` | ⚠️ re-fill per real instance |
| System Security Plan (VPDSS E11.010) | Worked example: server-instance-template `docs/compliance-pack/` | ⚠️ re-fill per real instance |
| Third-party/supplier posture (DH §24; VPDSS Std 8) | CI evidence exists; no questionnaire-ready pack | ⚠️ WS-A7 |
| EDR coverage (DH/HSV sector expectation) | auditd + AIDE + audit→ntfy (not an EDR product) | ⚠️ decision — WS-C2 |
| Availability/host-down alerting (VPDSS Std 7) | External dead-man's switch, required by provisioning | ✅ (WS-B7 shipped) |
| Evidence on demand (audit efficiency) | `audit-all.yml` one-command bundle + CI evidence page | ✅ (WS-B8 shipped) |

---

## 3. Workstreams

### WS-A · Governance & evidence documents (no code, highest audit leverage)

These live in the **server repo** (per-instance, may contain deployment specifics) with
generic templates in the scaffold (`docs/templates/`).

- **A1 · System Security Plan (SSP).** Assemble from docs/08 + 05 + 07: system purpose,
  data classes handled, architecture diagram, control inventory keyed to ISM/E8/CIS IDs,
  exceptions register (already exists), assessment history. VPDSS E11.010-shaped so it
  serves both a hospital reviewer and a VPDSS pass-through. Include the ISM-1409
  defensibility chain (CIS = Ubuntu vendor guidance) and a PQC posture paragraph.
- **A2 · Information asset register + BIL.** One table: each app, the health information
  classes it stores, C-I-A Business Impact Levels per the VPDSF BIL table (identifiable
  health data typically BIL-2 → OFFICIAL: Sensitive), where it lives (volume, backup
  repo), retention class. This is the first thing both OVIC-style and VAGO-style reviews
  ask for, and it drives every "is this control proportionate" argument.
- **A3 · HPP 9 / hosting jurisdiction record.** Provider name and ownership, region of
  VPS + backups (note the S3 backup bucket region — backups are a transfer too), the
  9.1 ground relied on, contract/DPA clauses. Template in scaffold; completed per
  instance. See WS-C1 for the decision itself.
- **A4 · Retention & deletion design note (HPP 4.2–4.4).** Platform stance: the app
  database is the record of record; restic pruning (7d/4w/6m) is *copy* lifecycle, not
  record deletion — record deletion happens at app level, honouring 7-year/age-25, with
  the app producing deletion logs. State that backup retention must always be shorter
  than record retention obligations are long (i.e. pruning old snapshots of data still
  live in the DB is fine; deleting the *only* copy is an app-level, logged act). One
  page; prevents the most common HPP 4 misunderstanding in review.
- **A5 · Incident response runbook.** Detection sources (ntfy channels, AIDE, auditd,
  Trivy criticals) → triage → containment (documented `ufw deny` / compose-down
  break-glass) → **notification tree: eHealth IMT within the hour (1300 598 686 /
  Digital.Health.Incident.Notification@health.vic.gov.au), health service CISO, HCC
  (encouraged 14 days), NDB if private-provider data, ASD ransomware-payment 72h** →
  evidence preservation (off-host logs, WS-B3) → recovery via restore drill procedure.
  Test annually; keep the test record in `reports/`.
- **A6 · Access review cadence.** Quarterly review of `authorized_keys`, admin emails in
  the auth tier, S3/SES credentials; recorded as a dated markdown entry in the server
  repo. Satisfies the E8 ML2 revalidation intent at single-admin scale and gives VAGO's
  "stale accounts" probe a paper trail.
- **A7 · Supplier-assessment pack.** Pre-answered security questionnaire (ISO
  27001-*aligned* program description mapped to the SSP, pen-test/vuln posture = the
  evidence bundle, SDLC = CI gates), so a hospital procurement/security review can be
  answered in a day. Generalise into
  `docs/compliance-handover-template.md` (roadmap P2-2 absorbs into this).

### WS-B · Technical controls (scaffold changes; each lands with its evidence artifact)

- **B1 · Encryption at rest** *(roadmap P0-1; HPP 4, VPDSS E11.140)* —
  1. **Now:** encrypted swap by default (`/etc/crypttab` random-key
     `aes-xts-plain64`, or zram) in `os-hardening`; closes the PII-in-swap hole on
     existing boxes. 2. **Opt-in:** LUKS-on-loopback/gocryptfs data-volume mount for
     app/DB volumes (`host_encrypt_data_dir`). 3. **Next provision:** provider-level
     encrypted volumes or LUKS root with remote unlock — a *provisioning-path decision*;
     document per provider in `03-provisioning-a-server.md`. Evidence: `lsblk`/crypttab
     capture in the bundle.
- **B2 · Patch & vulnerability SLA machinery** *(ISM 48h/2wk; E8 ML1 daily scanning)* —
  commit `audit-vuln.yml`; add a **daily systemd timer** on-host running the Trivy scan
  with ntfy alert on fixable CRITICALs (the 48-hour clock starts at detection — daily
  scanning is the floor that makes the SLA meetable); add a weekly pending-OS-updates
  check (`apt-get -s upgrade` delta) alerting when security updates sit unapplied
  > 48h. Evidence: dated scan reports + an SLA log (detection → patched timestamps).
- **B3 · Off-host, tamper-evident, 12-month logs** *(ISM-1988/1815; roadmap P0-2)* —
  two tiers, both scaffold-supported:
  - **Tier 1 (no SIEM dependency, do now):** nightly export of auditd/auth/caddy JSON
    logs, compressed + SHA-256 hash-chained, shipped to the existing S3 destination
    under an **object-locked / append-only** prefix with 12-month lifecycle. Uses
    infrastructure the scaffold already has; satisfies "off-host, tamper-evident,
    12 months, searchable" (searchable = structured JSON + dated keys) at 2 GB-VPS scale.
  - **Tier 2 (org SIEM available):** rsyslog `omfwd` over TLS/RELP to the collector
    (`log_forward_target` + CA vars) — first-class opt-in, forwards auditd + auth +
    audit-notify events in real time.
  Evidence: bucket listing + retrieval demo in the bundle.
- **B4 · MFA defaults** *(ISM-1173; E8 ML2)* — flip `TOTP_ENABLED=true` as the
  documented default for admin accounts in the auth tier; document the full factor
  story in `05-access-model.md`: admin = key-only SSH (possession) + TOTP on app admin;
  users = email-OTP single factor with a stated rationale + upgrade path. Add a
  phishing-resistant-MFA (WebAuthn) item to the auth service backlog for ML2 aspiration.
  Evidence: auth config capture + docs.
- **B5 · Backup restore drill + delete-resistant repo** *(ISM-1810–1814; roadmap
  P1-4)* — finish `restore-drill.sh` (the `--no-files` groundwork is already in
  `restore.sh`): restore latest snapshot to a throwaway target, integrity-assert, record
  **RPO/RTO achieved** to `reports/`, optional monthly timer. Move the S3 backup bucket
  to object-lock/versioning or an append-only restic REST credential so on-box
  credentials cannot destroy history (ISM-1814). Evidence: drill reports.
- **B6 · Tier separation assertion** *(ISM-1269/1270/1271)* — extend
  `check-compose-hardening.py` to assert: every app's DB container sits on a per-app
  network, publishes no ports, and is reachable only from its own app service; flag any
  unrelated app containers sharing a proxy network unnecessarily. Turns an ISM control into a CI
  gate. Evidence: audit-compose report.
- **B7 · External dead-man's switch** *(VPDSS Std 7; roadmap P1-5)* — `notify`-role
  timer curling Healthchecks.io/UptimeRobot (`deadman_switch_url`, opt-in). Evidence:
  monitor history screenshot/export in the bundle.
- **B8 · One-command evidence bundle** *(roadmap P2-2, upgraded)* — `audit-all.yml`:
  OpenSCAP (L2 profile for this deployment profile), docker-bench, audit-compose,
  audit-vuln, Lynis + **captures**: crypttab/lsblk, ufw status, auth config, backup +
  restore-drill reports, off-host log listing → single dated `reports/<host>-<date>/`
  with an `INDEX.md` where **every artifact is tagged with the control IDs it
  evidences** (HPP 4 / ISM-xxxx / E8 strategy / VPDSS E11.xxx / DH-baseline row). That
  index *is* the audit response.
- **B9 · Supply-chain gate + benchmark refresh** *(roadmap P1-1 + drift)* — CI lint
  failing on unpinned `:latest` for security-critical images; pin scaffold-owned
  auth/ntfy images by digest; watch items recorded in the exceptions register: SSG
  profiles still track CIS Ubuntu 24.04 **v1.0.0** (catalogue now v2.0.0, June 2026)
  and docker-bench trails CIS Docker **v1.8.0** — adopt as upstream content lands.
- **B10 · Deploy/admin privilege split** *(E8 restrict-admin; docs/05 target model)* —
  implement the documented-but-unbuilt split: `deploy` loses passwordless-ALL sudo and
  the docker group in `deploy_restricted_mode`; `admin` break-glass account.
  De-prioritised below B1–B8 (single-operator reality; auditd already records sudo),
  but it closes the loudest finding in docs/05 and the `sudo_require_authentication`
  L2 exception shrinks with it.

### WS-C · Per-deployment decisions (documented, not coded)

- **C1 · Hosting jurisdiction.** Decide and record per instance (template A3):
  - **Defensible default for identifiable Victorian health data:** Australian-region
    provider, ideally IRAP-assessed (hyperscaler AU regions, or Australian-owned VPS
    providers such as Binary Lane — verify current status at decision time), HPP 9
    satisfied via 9.1(a).
  - **Offshore/foreign-owned (e.g. Hetzner, OVH):** lawful only with a documented
    9.1(f) contract-plus-controls position; expect it to be challenged in a hospital
    review (OVIC flags foreign-owned providers even for onshore data). At-rest
    encryption (B1) + client-side-encrypted backups strengthen but don't complete the
    position. If the current instance is offshore, treat **migration or a written
    risk acceptance by the health service** as a P0 agenda item.
  - **Never** host MHR-system-connected workloads on this platform (s 77).
  - Backups count: the restic S3 bucket region belongs in the same record.
- **C2 · EDR posture.** DH/HSV describe EDR as required sector-wide (the central HSV
  agreement is the sponsored route). For a self-hosted VPS outside the hospital SOE,
  either (a) install the health service's EDR sensor if they'll enrol a Linux VPS, or
  (b) document a compensating-controls position (auditd immutable rules + AIDE +
  real-time audit→ntfy + Trivy + AppArmor) **and get it accepted in writing** via the
  health service's exemption pathway. Decide per engagement; record in the SSP.
- **C3 · Formal scope determination.** One paragraph, per instance, answering: is the
  operator acting as a contracted service provider to a Part 4 body (→ VPDSS applies
  contractually, SRPA/PDSP artifacts required — next PDSP window closes **31 Aug
  2026**)? Is the host a SOCI-designated hospital asset? Is any app private-practice
  (→ Privacy Act/NDB)? This determines which of A1–A7 are mandatory vs best-practice.

---

## 4. Reproducibility & auditability: how an instance proves it

1. **Provision = code.** `bootstrap.yml` + `site-first-run.yml` from a tagged scaffold
   commit produce the hardened state; the server repo pins the scaffold submodule —
   the exact hardening applied to any instance is a git SHA. Record the SHA in the SSP.
2. **Verify = playbooks.** `audit-all.yml` (B8) regenerates the full evidence bundle on
   demand; weekly `compliance-audits.yml` CI proves the *scaffold itself* continuously
   against a clean VM, catching regressions before they reach instances.
3. **Map = control matrix.** `docs/templates/vic-health-control-matrix.md`: one row per
   control — columns: DH baseline row (once obtained) · HPP · ISM ID · E8 strategy ·
   VPDSS element · implementing role/file · evidence artifact path. The bundle's
   `INDEX.md` is generated from it. This is the single document that makes the audit
   *reproducible*: same matrix + same playbooks + same SHA → same evidence.
4. **Exceptions = register.** Every deliberate deviation (cloud-N/A CIS rules, caddy
   NET_BIND_SERVICE, benchmark version lag, EDR compensating controls) stays in the
   docs/08 register with rationale — auditors respect a maintained register far more
   than a silent 100%.
5. **Attest = handover pack.** A1 SSP + A2 register + A3 jurisdiction record + latest
   bundle + drill/access-review logs = the pack that answers a VMIA self-assessment,
   a hospital security review, or a VPDSS pass-through with the same artifacts.

## 5. Sequencing

| Phase | Items | Effort | Rationale |
|---|---|---|---|
| **1 · Ship what's started** (days) | Commit audit-vuln + daily timer (B2), restore drill (B5), digest-pin CI gate (B9), dead-man's switch (B7) | Low | Roadmap "now" items, already half-built on this branch |
| **2 · Evidence layer** (1–2 weeks) | Control matrix + SSP (A1), asset register/BIL (A2), jurisdiction record (A3/C1), IR runbook (A5), retention note (A4), scope determination (C3) | Low–Med, mostly writing | Highest audit leverage per hour; unblocks any review happening *now* |
| **3 · Control gaps** (2–4 weeks) | Encrypted swap (B1.1), off-host logs Tier 1 (B3), TOTP default + access-model docs (B4, A6), tier-separation gate (B6), audit-all bundle (B8) | Med | The four named-control gaps auditors will actually cite |
| **4 · Structural** (next provision / org dependency) | Volume/FDE encryption (B1.2–3), SIEM forwarding Tier 2 (B3), EDR decision (C2), privilege split (B10), supplier pack (A7) | Med–High | Need a rebuild, an external destination, or a counterparty |

> Status note (2026-07-05): Phases 1 and 3 shipped (feat/security-audit-remediation);
> a filled worked example of the WS-A pack lives in server-instance-template
> `docs/compliance-pack/`. Outstanding: B4 (TOTP flip), B1.2–3, C1/C2 decisions, A7.
>
> Keep this plan, the [roadmap](compliance-roadmap.md), and the docs/08 exceptions
> register in lock-step as items land. Re-verify the fast-moving facts at each audit:
> ISM release (quarterly), E8MM version, CIS/SSG versions, the DH Policy & Funding
> Guidelines §24 (annual), and the unpublished 2025–2029 Health Sector Cybersecurity
> Strategy / "Cyber Safe Victoria 2026+" when they appear.

## 6. Primary references

- Health Records Act 2001 (Vic), authorised No. 050 (1 May 2026), Sch 1 HPPs —
  legislation.vic.gov.au/in-force/acts/health-records-act-2001
- DH Policy and Funding Guidelines 2025-26, Policy Guide §24 —
  health.vic.gov.au/policy-and-funding-guidelines-for-health-services
- VMIA Health Sector Cyber Security Assessments —
  vmia.vic.gov.au/health-sector-cyber-security-assessments
- VPDSS 2.0 + Implementation Guidance V2.4 (Jan 2026); VPDSF v2.1; 2026 PDSP How-To —
  ovic.vic.gov.au/information-security/standards/
- PDP Act 2014 (Vic) s 84(2), s 88(2) (health-service exclusion; CSP flow-down)
- OVIC, Outsourcing in the Victorian public sector (Mar 2025); IPP 9 guidelines —
  ovic.vic.gov.au
- ACSC ISM (June 2026); Hardening Linux workstations and servers (Nov 2023); E8
  Maturity Model (Nov 2023) + FAQ; Best Practices for Event Logging (Aug 2024) —
  cyber.gov.au
- CIS Ubuntu 24.04 v2.0.0 (Jun 2026); CIS Docker v1.8.0 (2025) — cisecurity.org
- VAGO: Cybersecurity: IT Servers (Oct 2025); Security of Patients' Hospital Data
  (2019); Cybersecurity: Cloud Computing Products (2023) — audit.vic.gov.au
- My Health Records Act 2012 (Cth) s 77; SOCI CIRMP rules; Cyber Security Act 2024
