# Retention & deletion design — ⟨host⟩

HPP 4.2 (Health Records Act 2001 Vic): a health service provider must not
delete health information earlier than **7 years after the last service — or,
for information collected while the individual was under 18, until they turn
25 — whichever is later**. HPP 4.3 requires deletions to be logged (name,
period covered, date); HPP 4.4 requires transfer logging.

## The platform stance (one paragraph an auditor can accept)

The **application database is the record of record**; retention obligations
attach to it, not to backup copies. restic's snapshot pruning
(default keep 7 daily / 4 weekly / 6 monthly) is *copy lifecycle management* —
it discards redundant snapshots of data that still lives in the database, so
it is not a HPP 4.2 deletion. A HPP 4.2 deletion happens only at application
level, is subject to the 7-year/age-25 rule, and must produce a deletion log.
The invariant: **no snapshot prune may ever remove the only remaining copy of
undeleted health information** — which holds automatically while the live
database retains the record.

## Per-app retention

| App | Record types | Retention rule | Deletion mechanism | Deletion log |
|---|---|---|---|---|
| ⟨app⟩ | ⟨clinical records⟩ | 7yr/age-25 (HPP 4.2) | ⟨app admin function / none — records kept indefinitely⟩ | ⟨where the app writes HPP 4.3 logs⟩ |
| auth service | accounts, session data | operational — removed when access revoked | admin removal + key rotation | quarterly access review entries |
| host logs | auditd/auth/access | 12 months (ISM-1988) ⟨pending off-host shipping, B3⟩ | age-based rotation | n/a (not health records) |

## Decommissioning

On instance retirement: final backup verified via restore drill → records
transferred/archived per HPP 4.4 (logged) → volumes and swap wiped
⟨method — provider secure-delete / crypto-erase once at-rest encryption (B1)
lands⟩ → restic repository retained/destroyed per the same retention rule →
this record updated with dates and signatures.

**Owner:** ⟨name⟩ · **Last review:** ⟨date⟩
