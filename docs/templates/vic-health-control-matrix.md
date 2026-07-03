# Control matrix — ⟨host⟩

One row per control: which standard demands it, what implements it, and where
the evidence lives. The DH column maps to the **Baseline Cybersecurity
Controls** workbook (VMIA hub) — fill it when the workbook is available;
the matrix stands on the HPP/ISM/E8/VPDSS columns without it.

Legend: ✅ implemented · ⚠️ partial/pending item ⟨ref⟩ · ➖ per-deployment decision.
Evidence paths are on-host unless prefixed `reports/` (fetched by the audit
playbooks) or `CI`.

| # | Control | HPP | ISM | E8 | VPDSS | DH | Implemented by | Evidence | Status |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Host OS hardened to CIS Ubuntu 24.04 (L1; L2 opt-in) | 4.1 | 1409 | — | E11.090 | ⟨⟩ | `os-/ssh-/baseline-hardening` roles | `reports/openscap-*` + tailoring file + docs/08 exceptions register | ✅ |
| 2 | Docker daemon hardened (CIS Docker §1–4) | 4.1 | 1409 | — | E11.090 | ⟨⟩ | `docker` role | `reports/docker-bench-*` | ✅ |
| 3 | Containers non-root, cap-dropped, read-only, no-new-privs (CIS §5) | 4.1 | 1409 | app hardening | E11.090 | ⟨⟩ | compose §5 blocks | `reports/compose-audit-*` + CI KICS | ✅ |
| 4 | Key-only SSH, root locked, no password auth | 4.1 | 0484/0485 | restrict admin | E11.120 | ⟨⟩ | `ssh-hardening`, `deploy-user` | openscap SSH rules; `sshd -T` capture | ✅ |
| 5 | MFA for privileged/app access | 4.1 | 1173 | MFA | E11.120 | ⟨⟩ | auth tier TOTP for admins | auth `.env` capture (`TOTP_ENABLED`) | ⚠️ B4 (default flip) |
| 6 | Firewall default-deny in/out; Docker-aware | 4.1 | — | — | E11.130 | ⟨⟩ | `firewall` role | `ufw status verbose` capture | ✅ |
| 7 | TLS for all external access (ACME, auto-HTTPS) | 4.1 | crypto ch. | — | E11.140 | ⟨⟩ | Caddy | cert chain / SSL Labs capture | ✅ |
| 8 | OS security patches auto-applied; SLA backstop alert | 4.1 | patch SLAs | patch OS | E11.040 | ⟨⟩ | unattended-upgrades + `pending-security-updates.timer` | journal `PATCH-SLA` lines | ✅ |
| 9 | Daily CVE scan of running images; 48h clock on fixable CRITICALs | 4.1 | patch SLAs | patch apps | E11.040 | ⟨⟩ | `vuln-scan.timer` (+ `audit-vuln.yml`) | `/var/lib/vuln-scan/<date>/` · `reports/vuln-*` | ✅ |
| 10 | Application control equivalent (image allowlist + digest pins + AppArmor) | 4.1 | 1409 | app control | E11.090 | ⟨⟩ | compose includes + digest pins + AppArmor enforce | CI `image-pins` job; `aa-status` capture | ✅ |
| 11 | Audit logging: auditd (immutable L2), AIDE, real-time alerts | 4.1 | 1988 partial | — | E11.110 | ⟨⟩ | `baseline-hardening`, `notify` | auditd rules capture; ntfy history | ✅ |
| 12 | Logs off-host, tamper-evident, 12-month searchable | 4.1 | 1988/1815 | — | E11.110 | ⟨⟩ | — | — | ⚠️ B3 (planned) |
| 13 | Backups encrypted, hourly, integrity-checked weekly | 4.1 | 1810/1811 | backups | E11.180 | ⟨⟩ | `backup` role (restic) | `backup-verify` journal; restic config capture | ✅ |
| 14 | Restore tested with RPO/RTO recorded | 4.1 | 1810+ | backups | E11.180 / Std 7 | ⟨⟩ | `restore-drill.timer` | `/var/lib/backup-drill/latest.txt` | ✅ |
| 15 | Backup history protected from on-box credential compromise | 4.1 | 1814 | backups | E11.180 | ⟨⟩ | — (object-lock / append-only repo) | bucket policy capture | ⚠️ B5b (planned) |
| 16 | Encryption at rest (swap, data volumes, disk) | 4.1 | crypto ch. | — | E11.140 | ⟨⟩ | — | `lsblk`/crypttab capture | ⚠️ B1 (planned) |
| 17 | Host-down alerting (external dead-man's switch) | — | — | — | Std 7 | ⟨⟩ | `vps-deadman.timer` (`notify_deadman_url`) | monitor history export | ✅ (opt-in URL) |
| 18 | Web/DB tier separation per app | 4.1 | 1269–1271 | — | E11.130 | ⟨⟩ | per-app compose networks | `reports/compose-audit-*` | ⚠️ B6 (gate planned) |
| 19 | Asset register with BILs | — | — | — | Std 2 | ⟨⟩ | [information-asset-register.md](information-asset-register.md) | the register | ➖ per instance |
| 20 | Hosting jurisdiction documented with HPP 9 ground | 9 | — | — | Std 8 | ⟨⟩ | [hosting-jurisdiction-record.md](hosting-jurisdiction-record.md) | the record | ➖ per instance |
| 21 | Retention/deletion honours 7-year/age-25 + deletion logs | 4.2–4.4 | — | — | — | ⟨⟩ | app level + [retention-deletion-design.md](retention-deletion-design.md) | app deletion logs | ➖ per instance |
| 22 | Incident response wired to DH 1-hour reporting | — | — | — | Std 6 | ⟨⟩ | [incident-response-runbook.md](incident-response-runbook.md) | runbook + annual test record | ➖ per instance |
| 23 | Quarterly access review (keys, admin emails, credentials) | 4.1 | — | restrict admin | E11.120 / Std 4 | ⟨⟩ | review cadence (see SSP §6) | dated review entries in repo | ➖ per instance |
| 25 | Secrets handling: 0600 file-based, AIDE-monitored, encrypted off-host copies, documented rotation (HPP 4; VPDSS E11.150) | 4.1 | 1449 analog | — | E11.150 | ⟨⟩ | `.env` pattern + `env-files` restic service + docs/08 secrets position | recovery-root entry in password manager; `restic snapshots --tag env-files` | ➖ enable per instance |
| 24 | EDR or accepted compensating controls | — | — | — | — | ⟨⟩ | auditd+AIDE+ntfy+Trivy stack | written acceptance from health service | ➖ decision C2 |

**Version note (⟨date⟩):** measurement of record is CIS Ubuntu 24.04 **v1.0.0**
(SSG profiles; catalogue at v2.0.0) and CIS Docker **v1.6.0** (docker-bench;
catalogue at v1.8.0) — tracked in the docs/08 exceptions register.
