# Incident Response

What to do when an alert (or a gut feeling) says the box is compromised or
data may have been exposed. The scaffold gives you detection, evidence, and a
rebuild path; this runbook sequences them and adds the notification duties
that apply to Victorian health workloads. Read it once now — during an
incident you should be following it, not discovering it.

**Companion docs:** [09-recovery.md](09-recovery.md) (rebuild),
[05-access-model.md](05-access-model.md) (break-glass access, repo-to-root
boundary), [08-security-model.md](08-security-model.md) (what's controlled).

## 0. Detection — where incidents announce themselves

All of these arrive via ntfy; know what each means before you need to:

| Signal | Source | Typical meaning |
|---|---|---|
| AIDE integrity change / `dailyaidecheck` failure | AIDE sweep | Host file tampering (or an unrecorded legitimate change) |
| Real-time audit event | auditd → ntfy bridge | Crown-jewel config touched (sshd_config, sudoers, passwd) NOW |
| Container unhealthy / restart-looping | vps-container-watch | App compromise, resource exhaustion, or plain crash |
| Unit failure (ssh, docker, fail2ban, backup…) | OnFailure hooks | Service-level failure — also how tampering often first surfaces |
| Auth-denial spike / new listening socket | weekly digest | Probing of the login wall; unexpected service exposure |
| Silence (external monitor alarms) | dead-man's switch | Host down — outage or takeover |

A **quiet channel plus a failed monthly self-test** is itself an incident:
your detection layer is broken.

## 1. Triage (first 15 minutes)

1. Do not touch the box yet. From your laptop, note the time (UTC) and start
   an incident log — a dated text file; every action and timestamp goes in it.
   It becomes the notification-report backbone later.
2. Corroborate: does the alert have a boring explanation (a deploy you just
   ran, a Renovate automerge, the patch-window reboot)? Check the repo's
   recent merges and the auto-deploy timer schedule first.
3. Classify. **A** operational (crash, disk, cert) → fix forward, no IR.
   **B** suspected host/app compromise → continue below.
   **C** confirmed or likely exposure of health information → continue below
   AND start the notification clock (§4) immediately, in parallel.

## 2. Contain

Order matters: preserve evidence before destroying state, cut exposure before
investigating at leisure.

1. **Snapshot first** — take a provider-console disk snapshot of the running
   box. This is your forensic image; everything after this step mutates state.
2. **Cut inbound exposure** at the provider firewall/console (all ports, or
   all but your own IP for SSH). Prefer the provider layer: it works even if
   the host firewall is attacker-controlled.
3. **Freeze the deploy chain** — the repo is a root-execution path:
   `systemctl stop auto-deploy.timer`, and disable Renovate automerge (or lock
   `main`) until the incident is closed. If GitHub account compromise is
   plausible, rotate its credentials and review recent merges NOW.
4. **Break-glass access** is the `admin` account (docs/05). Assume `deploy`
   and any app-level identity are burned.
5. If health information exposure is possible, treat containment steps as
   evidence too — screenshot provider console actions into the incident log.

## 3. Investigate on the evidence, not the box

The scaffold ships evidence off-host precisely so you don't have to trust a
compromised machine's own story:

- **Object-Locked S3 log bucket** (log-export role) — journal/auth/audit logs,
  tamper-evident, up to the last export. This is your primary timeline source.
- **AIDE report** — which files changed, against the last known-good baseline.
- **The provider snapshot** from §2 — mount read-only on a clean machine if
  deeper forensics is needed.
- **Restic snapshots** — append-only against the Object-Locked bucket; use to
  establish when data last looked right, and as the clean-restore source.
- The **access log's `user` field** (injected by the route renderer) gives
  per-authenticated-user request attribution for scoping what was viewed.

Questions to answer, in order: initial access vector → time window → what ran
as root → what data was reachable in that window (per-app networks bound the
blast radius: one app's compromise reaches its own backend + whatever Caddy
exposed to that user population).

## 4. Notify — Victorian health obligations

Get legal/governance advice early; this section is a map, not advice.

- **Engaged by a health service** (the usual posture for this platform): the
  health service's own incident pathway comes first — their CISO/privacy
  officer, per your agreement. They own onward reporting (Department of
  Health cyber incident reporting, OVIC where applicable). Your deliverable
  is the incident log + timeline from §1–3, fast.
- **Health Records Act**: exposure of identifiable health information can
  ground complaints to the **Health Complaints Commissioner** — the health
  service decides notification posture; give them accurate scope (whose
  records, what fields, what window).
- **Private-practice apps** (Privacy Act entities): the Commonwealth
  **Notifiable Data Breaches** scheme applies — "eligible data breach"
  assessment within 30 days, OAIC + affected-individual notification if
  serious harm is likely. The 30-day clock starts at *awareness*, which is §1.
- **SOCI-designated assets**: mandatory ACSC reporting timelines (12/72 h)
  apply — this should already be recorded in the instance's scope
  determination (compliance plan C3).

## 5. Eradicate and recover

Do not disinfect in place — **rebuild** (docs/09): fresh VPS, provision from
the repo, restore data from a restic snapshot that predates the incident.
Before cutover:

1. Rotate **everything in the recovery bundle** (inventory tokens, `.env`
   secrets, backup credentials, SMTP, ntfy tokens) and the auth service's
   `SESSION_SECRET` (invalidates all sessions). Re-run
   `make-recovery-bundle.sh` afterwards.
2. Rotate SSH keys and GitHub credentials if the vector is unclear.
3. Repoint the dead-man's switch and ntfy at the new box before DNS cutover.
4. Close the vector: the fix lands as a PR (scaffold or instance), with the
   incident log reference in the commit message.

## 6. Close out

- Write the post-incident note: vector, window, data scope, notifications
  made, fix. Store it with the instance's compliance evidence.
- Record the recovery time in docs/09's RTO log — real incidents are the
  drill nobody wanted.
- Re-enable auto-deploy and automerge once `main` is trusted again.
- If any control failed silently (an alert that should have fired and
  didn't), that's a scaffold bug — fix it upstream so every instance gets it.
