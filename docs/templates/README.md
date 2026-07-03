# Compliance evidence templates

Copy these into a **server repo** (e.g. `compliance/`) and fill in the
`⟨angle-bracket⟩` placeholders per instance. Together with the audit
playbook outputs in `reports/`, the completed set is the handover pack that
answers a hospital security review, a VMIA self-assessment, or a VPDSS
pass-through with the same artifacts.

| Template | What it answers | Standard hook |
|---|---|---|
| [scope-determination.md](scope-determination.md) | Which frameworks bind *this* instance | PDP Act s 84/88, SOCI, Privacy Act |
| [information-asset-register.md](information-asset-register.md) | What data is here and how much it matters | VPDSS Std 2 (BIL), VAGO inventory |
| [system-security-plan.md](system-security-plan.md) | How the system is secured, end to end | VPDSS E11.010, ISM SSP |
| [vic-health-control-matrix.md](vic-health-control-matrix.md) | Control → implementation → evidence map | all (the audit index) |
| [hosting-jurisdiction-record.md](hosting-jurisdiction-record.md) | Where the data physically lives and why that's lawful | HPP 9 / IPP 9 |
| [retention-deletion-design.md](retention-deletion-design.md) | How the 7-year/age-25 rule survives the platform | HPP 4.2–4.4 |
| [incident-response-runbook.md](incident-response-runbook.md) | Who does what, within the hour | DH Policy Guide §24.4 |

Background and sequencing: [../compliance-plan-vic-health.md](../compliance-plan-vic-health.md).
Keep the completed documents under version control in the server repo — the
git history *is* the review trail.
