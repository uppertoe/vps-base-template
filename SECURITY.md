# Security Policy

This repository is a VPS hardening scaffold: its whole purpose is security,
so reports are taken seriously and acted on quickly.

## Supported versions

The `main` branch only. Server repos consume the scaffold as a submodule and
pick up fixes by bumping the pointer (Renovate automates this for instance
repos with the submodule manager enabled).

## Reporting a vulnerability

Use **GitHub private vulnerability reporting** (Security tab → "Report a
vulnerability") on this repository. Please include the affected role/file,
an impact sketch (what an attacker gains), and reproduction steps if you
have them.

Expectations: acknowledgement within a few days; fixes land as ordinary PRs
(this repo's CI proves them) and flow to downstream instances via submodule
bumps. If a finding affects a live deployment's confidentiality, note it in
the report so rotation guidance can ship with the fix.

## Scope notes

- The threat model and control inventory live in
  [docs/08-security-model.md](docs/08-security-model.md); deliberate,
  documented exceptions are in its register — a report that an *excepted*
  control is absent is expected behaviour, not a vulnerability.
- Findings in upstream components (Caddy, Docker, devsec roles, ntfy,
  restic) belong upstream, but a report here is welcome if the scaffold's
  configuration makes an upstream issue exploitable.
