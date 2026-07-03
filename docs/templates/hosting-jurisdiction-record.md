# Hosting jurisdiction record — ⟨host⟩

HPP 9 (Health Records Act 2001 Vic) treats storing health information with a
provider **outside Victoria** as a transborder transfer needing a documented
ground under HPP 9.1(a)–(g). This record is that documentation. Keep it
current — it is the first artifact a privacy review requests.

## Where the data physically is

| Component | Provider | Provider ownership/HQ | Region/location | Notes |
|---|---|---|---|---|
| VPS | ⟨provider⟩ | ⟨e.g. US-owned; AU subsidiary⟩ | ⟨e.g. Sydney, AU⟩ | ⟨IRAP-assessed? HCF-certified?⟩ |
| Backups (restic) | ⟨S3-compatible provider⟩ | ⟨…⟩ | ⟨bucket region⟩ | client-side encrypted (restic AES-256) before upload |
| Transactional email | ⟨e.g. AWS SES⟩ | ⟨…⟩ | ⟨region⟩ | OTP emails contain addresses, no clinical data |
| External monitor | ⟨e.g. self-hosted Gatus on ⟨machine⟩⟩ | ⟨…⟩ | ⟨…⟩ | receives heartbeats only, no payload data |
| DNS / registrar | ⟨…⟩ | ⟨…⟩ | — | metadata only |

Administration is performed from: ⟨Australia only? note any offshore admin —
departmental practice treats offshore administration as offshore access⟩.

## Lawful basis (HPP 9.1 ground)

⟨Pick and evidence ONE per transfer:⟩

- **9.1(a) substantially similar law** — for interstate-AU hosting: the
  recipient is subject to the Privacy Act 1988 (Cth) APPs ⟨/ state equivalent⟩.
- **9.1(b) consent** — ⟨where users consent at collection; cite the wording⟩.
- **9.1(f) reasonable steps** — for offshore/foreign-owned providers:
  contract/DPA clause ⟨ref⟩ binding HPP-consistent handling, plus technical
  measures: client-side-encrypted backups, TLS, at-rest encryption ⟨status⟩.
  Note OVIC's caution: foreign-owned providers may face foreign
  law-enforcement access **even for data held in Australia** — record the
  risk assessment and who accepted it.

**Ground relied on:** ⟨…⟩ · **Assessed by:** ⟨name, role⟩ · **Accepted by:**
⟨health service contact if applicable⟩ · **Date:** ⟨…⟩

## Constraints acknowledged

- My Health Record data is **never** hosted here (MHR Act s 77 hard onshore
  prohibition — consent cannot override it).
- Backup bucket region counts as a transfer destination in its own right.
- Provider changes re-open this record before migration, not after.
