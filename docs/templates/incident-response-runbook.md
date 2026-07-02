# Incident response runbook — ⟨host⟩

**Owner:** ⟨name, phone⟩ · **Deputy:** ⟨name, phone⟩ · **Last test:** ⟨date⟩

> DH Policy & Funding Guidelines §24.4: significant ICT incidents go to the
> eHealth Incident Management Team **within the hour**; all cyber incidents
> (including supplier breaches) as soon as detected **or suspected**.

## 1. Detection sources

ntfy channel ⟨topic⟩ carries: auditd real-time config-tampering events, AIDE
integrity failures, unit failures (backup, docker, sshd, fail2ban), fixable
CRITICAL CVEs (vuln-scan), pending security updates (patch-SLA). External
monitor ⟨name/URL⟩ alarms on host-down. Manual: user reports, provider
notices.

## 2. Triage (15 minutes)

1. Confirm signal on a second source (`journalctl -u ⟨unit⟩`, `last`,
   `ausearch -ts recent -k ⟨key⟩`, `docker ps`).
2. Classify: ⟨A⟩ suspected compromise (integrity/tampering/unknown access) ·
   ⟨B⟩ availability (host/app down) · ⟨C⟩ vulnerability (fixable CRITICAL,
   no compromise indication) · ⟨D⟩ data breach indication (health information
   accessed/exfiltrated).
3. Class A or D → containment AND notification immediately, in parallel.

## 3. Containment (class A/D)

```
# Freeze inbound except your own admin IP, keep the box for forensics:
sudo ufw insert 1 allow from ⟨admin IP⟩ to any port 22 proto tcp
sudo ufw delete allow 80/tcp && sudo ufw delete allow 443/tcp && sudo ufw delete allow 443/udp
# Stop the app stack (containers are disposable; volumes hold the data):
cd /opt/deploy && docker compose down
```
Do **not** wipe or reprovision until evidence is preserved (§5). If the host
itself is untrusted, use the provider console to snapshot then isolate.

## 4. Notification tree

| Who | When | How |
|---|---|---|
| eHealth Incident Management Team (DH) | within the hour (significant) / on suspicion (all) | 1300 598 686 · Digital.Health.Incident.Notification@health.vic.gov.au |
| Health service CISO/IT security ⟨name⟩ | with the DH call | ⟨contact⟩ |
| System owner ⟨name⟩ | immediately | ⟨contact⟩ |
| HCC (Vic) | encouraged ≤14 days for health-privacy breaches | hcc.vic.gov.au |
| OAIC NDB | if private-provider data + likely serious harm (30 days assess) | oaic.gov.au |
| ASD ransomware payment report | 72h if any payment made (Cyber Security Act 2024) | cyber.gov.au/report |
| Hosting provider | per contract ⟨ref⟩ | ⟨contact⟩ |

## 5. Evidence preservation

Before any rebuild: provider disk snapshot ⟨how⟩; copy off-host —
`journalctl -o export`, `/var/log/audit/`, `caddy_logs` volume, AIDE
databases, `/var/lib/vuln-scan`, `docker inspect` of all containers; record
`date -u`, `who`, hashes of collected files. Store at ⟨secure location⟩.

## 6. Recovery

Reprovision from the scaffold (bootstrap → site-first-run → deploy), restore
data per `restore.sh` (drill-tested — latest RPO/RTO in
`/var/lib/backup-drill/latest.txt`), rotate **all** credentials (SSH keys,
auth `.env` secrets, S3 keys, SES, registry tokens), re-run the audit
playbooks, then post-incident review within ⟨2 weeks⟩ — findings feed the
control matrix and this runbook.

## 7. Annual test

Tabletop the worst plausible scenario (class D on the highest-BIL app);
record date, participants, gaps found, and fixes in the server repo.
