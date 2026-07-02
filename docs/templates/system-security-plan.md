# System Security Plan — ⟨host⟩

**System owner:** ⟨name, role⟩ · **Operator:** ⟨name⟩ · **Last review:** ⟨date⟩
**Scaffold version:** `vps-base-template @ ⟨git SHA⟩` (submodule pointer in the
server repo — the exact hardening code applied to this host).

## 1. Purpose and scope

⟨2–3 sentences: what the system does, who uses it, which organisation(s) it
serves. Name the apps hosted and link each to its row in the
[asset register](information-asset-register.md).⟩

Frameworks binding this instance: see
[scope-determination.md](scope-determination.md). Highest data classification
held: ⟨e.g. BIL-2 / OFFICIAL: Sensitive — identifiable health information⟩.

## 2. Architecture

⟨Diagram or description: single Ubuntu 24.04 VPS · Docker Compose stack ·
Caddy reverse proxy terminating TLS on 80/443 (only published ports) ·
per-app containers on the `caddy` network · per-app PostgreSQL where used ·
restic backups to ⟨S3 destination + region⟩ · ntfy alerting + external
dead-man's-switch monitor ⟨name⟩.⟩

Hosting: ⟨provider, region, ownership⟩ — details and lawful basis in the
[hosting jurisdiction record](hosting-jurisdiction-record.md).

## 3. Control inventory

The complete control → implementation → evidence map is the
[control matrix](vic-health-control-matrix.md). Summary of the defensibility
chain for the OS baseline (ISM-1409): the ISM requires ASD **and vendor**
hardening guidance; Canonical's vendor tooling for Ubuntu (USG) implements the
CIS benchmark, so the scaffold enforces and measures **CIS Ubuntu 24.04 Server**
(L1, with the L2 profile enabled on this host: ⟨yes/no⟩), verified by OpenSCAP
with a documented tailoring file, plus CIS Docker at the container layers.

## 4. Deliberate exceptions

Maintained in the scaffold's
[exceptions register](../08-security-model.md#exceptions-register) (cloud-N/A
CIS rules, public reverse-proxy ports, UFW-over-nftables, benchmark version
lag) plus per-instance exceptions: ⟨list, or "none"⟩.

## 5. Cryptography

In transit: TLS via Caddy/ACME (external), SSH (admin). At rest: restic
AES-256 for backups; host disk: ⟨state — see control matrix #16⟩.
**PQC posture:** the system's cryptography is delegated to Caddy/OpenSSH/
restic upstream defaults; migration to ML-KEM/ML-DSA suites follows Ubuntu
LTS and upstream releases, reviewed at each ⟨annual⟩ SSP review, target
completion before the ASD 2030 deadline.

## 6. Access

Model: [docs/05-access-model.md](../05-access-model.md). Current holders:

| Access | Who | Factor(s) | Reviewed |
|---|---|---|---|
| SSH (`deploy`) | ⟨names⟩ | ed25519 key (passphrase-protected) | ⟨date⟩ |
| App admin | ⟨emails⟩ | email OTP + TOTP | ⟨date⟩ |
| Backup S3 credentials | on-host root config | — | ⟨date⟩ |
| Registry / GitHub | ⟨names⟩ | ⟨MFA type⟩ | ⟨date⟩ |

Quarterly access review entries: ⟨link to review log in server repo⟩.

## 7. Assessment history

| Date | Assessment | Result | Report |
|---|---|---|---|
| ⟨date⟩ | OpenSCAP CIS ⟨L1/L2⟩ | ⟨pass %, exceptions⟩ | `reports/openscap-…` |
| ⟨date⟩ | docker-bench / compose audit | ⟨…⟩ | `reports/…` |
| ⟨date⟩ | Restore drill | RPO ⟨…⟩ RTO ⟨…⟩ | `/var/lib/backup-drill/…` |
| ⟨date⟩ | ⟨pen test / review⟩ | ⟨…⟩ | ⟨…⟩ |
