# Scope determination — ⟨host⟩

Which frameworks bind this instance, decided once and revisited when the
operating relationship changes. Sources: PDP Act 2014 (Vic) ss 84, 88;
Health Records Act 2001 (Vic); DH Policy & Funding Guidelines §24; SOCI Act;
Privacy Act 1988 (Cth). Background: docs/compliance-plan-vic-health.md §1.

| Question | Answer | Consequence |
|---|---|---|
| Does the system hold **health information** collected in Victoria? | ⟨yes/no⟩ | HRA HPPs apply directly (HPP 4 security/retention, HPP 9 transborder) — regardless of public/private status |
| Is the operator a **contracted service provider to a PDP Act Part 4 body** (e.g. the Department of Health — public health services themselves are excluded by s 84(2))? | ⟨yes/no — name the contract⟩ | If yes: VPDSS flows down via s 88(2) → SRPA + PDSP + attestation artifacts required (PDSP window: Jul–Aug of even years) |
| Is the system operated **for/within a public health service** subject to the DH Policy & Funding Guidelines? | ⟨yes/no — which health service⟩ | If yes: DH Baseline Cybersecurity Controls + VMIA self-assessment + §24.4 one-hour incident reporting apply; supplier risk sits with the health service |
| Is the host part of a **SOCI-designated critical hospital's** infrastructure? | ⟨yes/no⟩ | If yes: CIRMP obligations (E8 ML1 / ISO 27001 / equivalent, annual board report) |
| Does any app handle data for a **private practice** (APP entity)? | ⟨yes/no⟩ | If yes: Privacy Act 1988 + Notifiable Data Breaches scheme |
| Does anything connect to **My Health Record**? | ⟨no — keep it that way⟩ | If ever yes: s 77 onshore mandate + ADHA conformance — out of scope for this platform |

**Determination:** ⟨summarise: which of WS-A artifacts are mandatory vs
best-practice for this instance⟩.

**Made by:** ⟨name, role⟩ · **Date:** ⟨…⟩ · **Review trigger:** new contract,
new app, new data class, or organisational change.
