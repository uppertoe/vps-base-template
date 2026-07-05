# Adversarial Security Audit - 2026-07-05

This document collates an adversarial review of `vps-base-template` and the
downstream `server-instance-template` as they stood on 2026-07-05. The goal was
to find places where the hardening model overclaims, where controls can be
bypassed, or where a downstream repo can unintentionally weaken the scaffold's
security posture.

The review covered:

- `vps-base-template` Ansible roles, hardening docs, audit scripts, Docker/Caddy
  base compose, and CI/security workflows.
- `server-instance-template` compose files, app examples, deploy hooks, CI, and
  reports.
- A read-only runtime check against the staging VPS (`rch-vps`) to validate
  assumptions about user privileges, Docker networks, mounts, images, and
  firewall chains.

No secrets were intentionally printed or recorded. The staging inventory was
observed to contain live credentials in plaintext; treat that local file as
sensitive.

## Executive Summary

The host hardening work is strong in the areas that are explicitly measured:
SSH hardening, deploy restricted mode, CIS L2 audit rules, AppArmor, AIDE,
runtime container controls, digest-pinned compose services, and UFW on the host.
The main gaps are not basic missing hardening flags; they are boundary mistakes
between containers, repo code, and host root.

The highest-risk issues are:

1. The shared `caddy` Docker network allows app-to-app lateral traffic and
   undermines the auth header trust model.
2. Caddy mounts the entire deploy repository, giving the public reverse proxy
   read access to repo-local secret files.
3. Docker bridge traffic bypasses the host outbound-deny policy, so container
   egress is not actually constrained.
4. Deploy hooks and helper `docker run` paths bypass the compose image-pin and
   runtime-hardening gates.
5. Restricted mode confines the SSH `deploy` user, but repo-controlled deploy
   hooks still execute as root, including through auto-deploy.

## Severity Summary

| ID | Severity | Finding | Primary repo |
|---|---|---|---|
| A1 | High | Shared proxy network breaks app isolation and auth trust boundary | base + downstream |
| A2 | High | Caddy can read deploy repo secrets through broad bind mount | base |
| A3 | High | Container egress bypasses host outbound deny | base |
| A4 | High | Deploy hooks bypass image pinning/runtime hardening | downstream |
| A5 | High | Restricted mode still executes repo hooks as root | base + downstream |
| A6 | Medium | Trivy helper image is unpinned and mounts Docker socket | base |
| A7 | Medium | Compose audit only checks running long-lived containers | base |
| A8 | Medium | DB isolation detection is name-based and evadable | base |
| A9 | Medium | Restic binary download is not checksum/signature verified | base |
| A10 | Low | Auth docs are stale for current `import protected` syntax | base + downstream |
| A11 | Low | Local staging inventory stores live credentials in plaintext | downstream ops |

## Findings

### A1 - Shared `caddy` Network Breaks App Isolation and Auth Trust Boundary

Severity: High

The auth model says protected apps can trust `Remote-User`, `Remote-Email`, and
`Remote-Groups` because only Caddy can reach the app backend. In practice, every
app is instructed to join the same fixed `caddy` Docker network:

- `docs/04-server-repo.md` shows app services joining `networks: [caddy]`.
- `server-instance-template/apps/auth/auth.caddy` forwards auth-verified
  requests to app upstreams and copies `Remote-*` headers.
- `docs/07-auth.md` states that apps trust these headers because only Caddy can
  reach them.

Runtime validation on staging confirmed that the `caddy` network contains both
`deploy-caddy-1` and `deploy-ntfy-1`. On a host with multiple apps, any
compromised app container on that network can connect directly to another app's
backend and forge the trusted identity headers, bypassing Caddy and
`forward_auth`.

Impact:

- Compromise of one public app can become compromise of any protected app that
  trusts `Remote-*` headers for identity.
- This is a direct contradiction of the documented trust model.
- The current compose audit catches databases on the shared proxy network, but
  it does not catch app-to-app reachability.

Recommended remediation:

- Replace the global shared app network with per-app proxy networks, e.g.
  `caddy_dashboard`, `caddy_auth`, `caddy_ntfy`.
- Attach Caddy to every per-app proxy network, but attach each app only to its
  own proxy network plus any private backend network it needs.
- Update docs and templates so new apps define their own proxy network instead
  of joining `name: caddy`.
- Add an audit rule that fails if two non-Caddy app services share a proxy
  network, except for explicitly documented service pairs.

### A2 - Caddy Can Read Deploy Repo Secrets Through Broad Bind Mount

Severity: High

The base Caddy service mounts the whole server repo into the public reverse
proxy container:

```yaml
volumes:
  - ../..:/srv/repo:ro
```

This exists so `run-caddy.sh` can discover `apps/*/*.caddy`. That same mount
also exposes files such as:

- `/opt/deploy/.env`
- `/opt/deploy/apps/*/.env`
- `/opt/deploy/backup/config.env`
- `/opt/deploy/backup/services/*.env`

Staging validation confirmed:

- `/opt/deploy` is mounted into `deploy-caddy-1` as `/srv/repo`.
- `/srv/repo/.env` exists inside the Caddy container.
- Caddy runs as UID `1000`, matching the deploy-owned secret files in the
  default model, so mode `0600` does not protect those files from Caddy.

The staging host did not currently have all backup/app env files present under
that mount, but the template and deploy helper explicitly support them.

Impact:

- A Caddy compromise exposes server and app secrets, backup credentials, and
  potentially the env-files recovery root if present in `/opt/deploy`.
- The security docs correctly say file permissions are the secret boundary, but
  the Caddy UID and repo-root mount make that boundary weaker than stated.

Recommended remediation:

- Do not mount the deploy repo root into Caddy.
- Generate a sanitized Caddyfile/snippet bundle on the host and mount only that
  generated file or directory.
- Alternatively, require all Caddy snippets to live under a non-secret
  `routes/` directory and mount only that directory.
- Run Caddy under a dedicated UID that does not own deploy secrets.
- Add a CI or runtime audit check that fails if Caddy has a bind mount covering
  `.env`, `backup/`, or app directories containing `.env`.

### A3 - Container Egress Bypasses Host Outbound Deny

Severity: High

The host firewall defaults to outbound deny, but the Docker-aware firewall
helper returns all packets arriving from Docker bridge interfaces before it
checks any allowed destination ports:

```bash
iptables -A VPS-SCAFFOLD-DOCKER-USER -i docker0 -j RETURN
iptables -A VPS-SCAFFOLD-DOCKER-USER -i br+ -j RETURN
```

Staging validation confirmed the live chain has the same ordering for both IPv4
and IPv6. That means container-originated traffic bypasses the scaffold's
outbound port allowlist.

Impact:

- A compromised container can make arbitrary outbound connections, subject only
  to Docker/NAT and upstream network policy.
- The host-level "default outgoing deny" evidence overstates the egress posture
  for the actual internet-facing workload.

Recommended remediation:

- Decide whether unrestricted container egress is accepted or not.
- If accepted, document it explicitly in `docs/08-security-model.md`.
- If not accepted, replace the unconditional bridge `RETURN` rules with
  explicit DNS/NTP/HTTP/HTTPS/SMTP or per-app destination allowlists.
- Add an audit capture that demonstrates container egress behavior, not only
  host egress.

### A4 - Deploy Hooks Bypass Image Pinning and Runtime Hardening

Severity: High

The downstream ntfy deploy hook runs an unpinned helper image:

```bash
docker run --rm -v "${lib_vol}:/lib" -v "${cache_vol}:/cache" busybox \
  chown -R 1000:1000 /lib /cache
```

This path is outside the compose files, so it is missed by:

- `scripts/check-image-pins.sh`, which only checks compose `image:` lines.
- Renovate digest freshness.
- KICS compose scanning.
- `audit-compose.yml`, because the helper is transient.

Staging validation confirmed `busybox:latest` is present locally alongside the
digest-pinned running service images.

Impact:

- A mutable `latest` image runs during deploy with host Docker privileges and
  named volumes mounted.
- The supply-chain assertion "a deploy pulls exactly the bytes that were
  reviewed" is false for helper containers and scripts.

Recommended remediation:

- Remove the ntfy `busybox` path if `ntfy-init` fully handles volume ownership.
- Pin all script-level helper images by digest if any remain.
- Add CI checks for `docker run`, `docker pull`, `docker build`, and
  `docker compose run` in deploy hooks and scripts.
- Include script-level helper image pins in digest freshness checks.

### A5 - Restricted Mode Still Executes Repo Hooks as Root

Severity: High

Restricted mode successfully removes broad sudo and Docker group access from
the `deploy` SSH user. Staging validation confirmed:

- `deploy` has no passwordless sudo.
- `deploy` cannot access `/var/run/docker.sock`.

However, the root-owned `vps-deploy` wrapper executes every executable
`apps/*/deploy.sh` hook after `git pull`. The wrapper comments state that app
hooks run as root. The `auto-deploy` timer can call the same wrapper
unattended after upstream changes.

Impact:

- Restricted mode confines an interactive SSH user, but any actor who can merge
  to the server repo can execute root code on the VPS through a deploy hook.
- With `deploy_auto_update=true`, this can happen without an operator manually
  starting deploy.
- Branch protection, CODEOWNERS, and GitHub account security become part of the
  host root boundary.

Recommended remediation:

- Document this trust boundary directly in `docs/05-access-model.md`.
- Prefer fixed, root-owned allowlisted maintenance verbs over arbitrary
  repo-controlled shell hooks.
- If hooks remain, run them as `deploy` unless they explicitly need root.
- Add CODEOWNERS for `apps/*/deploy.sh`, root compose files, and workflow files.
- Require manual approval or a protected environment for auto-deploy on
  production hosts.

### A6 - Trivy Helper Image Is Unpinned and Mounts Docker Socket

Severity: Medium

The scheduled vulnerability scan runs Trivy as a container:

```bash
TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy:0.59.1}"
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock "$TRIVY_IMAGE" ...
```

The tag is versioned but not digest-pinned, and the container receives the
Docker socket.

Impact:

- A compromised or unexpectedly changed scanner image has Docker daemon access.
- The scanner path is outside the current image-pin/freshness gate.

Recommended remediation:

- Pin `vuln_scan_trivy_image` by digest.
- Include it in freshness monitoring.
- Consider installing a verified Trivy binary instead of granting a scanner
  container Docker socket access.

### A7 - Compose Audit Only Checks Running Long-Lived Containers

Severity: Medium

`check-compose-hardening.py` enumerates containers with:

```python
docker ps --format "{{.Names}}"
```

That excludes:

- Exited one-shot init services such as `caddy-init` and `ntfy-init`.
- Transient deploy hook helper containers.
- Transient scanner containers.

Impact:

- A clean `audit-compose.yml` result does not prove all container execution
  paths meet the stated CIS Docker section 5 posture.
- The staging compose report showed only `deploy-caddy-1` and `deploy-ntfy-1`.

Recommended remediation:

- Add a static `docker compose config` audit for all declared services, including
  `restart: "no"` init services.
- Add a script-level helper container audit, or ban helper containers outside
  compose.
- Record explicit exceptions for init containers that require root/capabilities.

### A8 - DB Isolation Detection Is Name-Based and Evadable

Severity: Medium

The compose audit detects databases by image basename markers:

```python
DB_IMAGE_MARKERS = ("postgres", "mysql", "mariadb", "mongo", "redis", "valkey")
```

A custom database image or proxy image that does not contain those strings can
avoid the DB network/port checks.

Impact:

- The audit can miss a stateful data service published to the host or placed on
  the shared proxy network.
- This weakens the stated ISM data-tier separation assertion.

Recommended remediation:

- Require stateful services to carry an explicit label, e.g.
  `vps-scaffold.role=db`.
- Fail unlabeled services with persistent volumes unless they declare a role.
- Audit by labels and network topology rather than image name heuristics.

### A9 - Restic Binary Download Is Not Checksum/Signature Verified

Severity: Medium

The backup role downloads a Restic release artifact from GitHub and installs the
decompressed binary, but does not verify a checksum or signature.

Impact:

- TLS protects transit, but there is no release-integrity check before placing a
  root-owned backup binary in `/usr/local/bin`.
- This is inconsistent with the stronger digest-pinning model used for compose
  service images.

Recommended remediation:

- Pin expected SHA256 checksums by Restic version and architecture.
- Or verify Restic's upstream signatures before install.
- Consider using Ubuntu-packaged Restic if version lag is acceptable.

### A10 - Auth Docs Are Stale for Current `import protected` Syntax

Severity: Low

The downstream `apps/auth/auth.caddy` defines `(protected)` as a snippet that
takes the upstream as an argument and performs `reverse_proxy` itself. The docs
still show:

```caddyfile
import protected
reverse_proxy dashboard:3000
```

That does not match the current snippet.

Impact:

- New apps can be configured incorrectly.
- Operators may believe a route is protected when the Caddy config is actually
  invalid or behaving differently than expected.

Recommended remediation:

- Update `docs/07-auth.md` and downstream README examples to use:

```caddyfile
dashboard.{$DOMAIN} {
    import protected dashboard:3000
}
```

- Update path-scoping examples similarly.
- Add a CI example that renders a protected demo app using the documented
  syntax.

### A11 - Local Staging Inventory Stores Live Credentials in Plaintext

Severity: Low

The local downstream inventory file is gitignored but contains live tokens and
cloud credentials in plaintext.

Impact:

- Local disk compromise exposes notification, log export, and related
  credentials.
- The file is outside git review and easy to forget during backup/sharing.

Recommended remediation:

- Ensure local inventory files are mode `0600`.
- Move secrets to Ansible Vault, SOPS, or an encrypted local secrets store.
- Rotate any credentials that were copied into chat, logs, screenshots, or
  other durable locations.

## Staging Validation Notes

Read-only SSH checks against `rch-vps` validated several important claims:

- Restricted mode works for the `deploy` user: no passwordless sudo and no
  Docker socket access.
- `admin` remains break-glass/root-equivalent: sudo works and it is in the
  `docker` group.
- Running services were `deploy-caddy-1` and `deploy-ntfy-1`.
- Public listeners were SSH, HTTP, HTTPS, QUIC, and loopback ntfy on 127.0.0.1.
- Caddy's bind mounts include `/opt/deploy` to `/srv/repo:ro`.
- The live `caddy` network contains Caddy and ntfy; downstream multi-app hosts
  would put every app on the same network under the current template.
- Local Docker images included digest-backed service images plus
  `busybox:latest` and `aquasec/trivy:0.59.1`, confirming helper-image paths
  outside compose pins.
- Live `DOCKER-USER` rules return traffic from Docker bridge interfaces before
  applying destination port allowlists.

## Recommended Remediation Order

1. Narrow Caddy's repo mount and move route discovery to a non-secret artifact.
2. Replace the shared `caddy` network with per-app proxy networks.
3. Decide and enforce/document container egress policy.
4. Remove or pin script-level helper containers, starting with ntfy's
   `busybox:latest`.
5. Make deploy hook trust explicit; preferably replace arbitrary root hooks with
   allowlisted root-owned commands.
6. Extend audits to cover static compose services, transient helper containers,
   scanner images, and DB role labels.
7. Add Restic release verification.
8. Correct auth docs and examples.
9. Move local inventory secrets into an encrypted workflow.

