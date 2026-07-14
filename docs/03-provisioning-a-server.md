# Provisioning a Server

A full walkthrough from creating a VPS to a hardened, Docker-ready server.

## Fast path — `./provision.sh`

Your server repo ships `scripts/provision.sh`, a re-runnable orchestrator that
chains every step below — bootstrap → hardening → AWS → backups → deploy →
alerting → recovery bundle → strict verify — into one idempotent command:

```bash
scripts/provision.sh <host>              # <host> = your inventory alias
scripts/provision.sh --dry-run <host>    # preview: prints each stage's skip/run
```

It prompts for at most two things — the root credential (only on the first
bootstrap, and only if the provider gave a root password) and the
recovery-bundle passphrase — and skips both on a converged re-run. Wire the AWS
buckets in the same pass with `--aws-backup-bucket/--aws-backup-user` and
`--aws-logs-bucket/--aws-logs-user` (needs an AWS admin profile via
`--aws-profile`). You still create the VPS and cut DNS over yourself.

The manual step-by-step below is the reference — what `provision.sh` runs in
order, and the fallback when a stage needs hand-holding.

## Step 1 — Create a VPS

At your hosting provider (Hetzner, DigitalOcean, Vultr, etc.):

1. Choose **Ubuntu 24.04 LTS** (or Debian 12)
2. Choose your server size (smallest works fine for a start)
3. **Paste your SSH public key** when prompted — this is how you'll connect:
   ```bash
   cat ~/.ssh/id_ed25519.pub
   # Copy the output and paste into the provider's SSH key field
   ```
4. Note the server's IP address once it's created

Test that you can connect as root:

```bash
ssh root@YOUR_SERVER_IP

# If you see a shell prompt, you're in. Type `exit` to return.
```

> If you can't connect, check the provider's firewall/security group settings.
> Port 22 must be open.

## Step 2 — Create an inventory file

In your server repo (or temporarily in this scaffold for testing), create an
inventory file from the example:

```bash
cp ansible/inventory/production.example ansible/inventory/myserver
```

`myserver` is just an example alias. Rename it if you like, but use the same
alias consistently in your inventory file, `~/.ssh/config`, and SSH commands.

Edit it:

```ini
[servers]
myserver ansible_host=YOUR_SERVER_IP

[servers:vars]
ansible_user=deploy
ansible_ssh_private_key_file=~/.ssh/id_ed25519
ansible_python_interpreter=/usr/bin/python3
```

## Step 3 — Install Ansible dependencies

If you haven't already:

```bash
ansible-galaxy collection install -r scaffold/ansible/requirements.yml
```

## Step 4 — Run the bootstrap playbook (once, as root)

This creates the `deploy` user and installs base packages. Connects as root.

```bash
ansible-playbook -i ansible/inventory/myserver ansible/bootstrap.yml
```

Expected output: a series of green `ok` and yellow `changed` lines. No red
`failed` lines.

> **If your provider gave you a root password instead of SSH key access:**
> ```bash
> ansible-playbook -i ansible/inventory/myserver ansible/bootstrap.yml --ask-pass
> ```
> You'll be prompted for the root password.

**What this does:**
- Updates all packages
- Installs common tools (curl, git, fail2ban, etc.)
- Creates the `deploy` user
- Copies your SSH public key into `/home/deploy/.ssh/authorized_keys`
- Grants `deploy` passwordless sudo

## Step 5 — Verify deploy user access

Before locking down SSH, confirm you can connect as the deploy user:

```bash
ssh deploy@YOUR_SERVER_IP
# or, if you set up ~/.ssh/config:
ssh myserver
```

You should get a shell prompt. Test that sudo works:

```bash
sudo whoami
# should output: root
```

If this works, exit and continue. **Do not proceed to step 6 if this fails**
— you'll lock yourself out.

```bash
exit
```

## Step 6 — Run the first-run site playbook (as deploy user)

This applies SSH hardening, OS hardening, installs Docker, configures the
firewall, and enables the slower first-run/compliance tasks.

```bash
ansible-playbook -i ansible/inventory/myserver ansible/site-first-run.yml
```

Use the quick path for routine updates later:

```bash
ansible-playbook -i ansible/inventory/myserver ansible/site-quick.yml
```

**What this does:**
- Hardens SSH (disables root login, password auth, restricts to deploy user)
- Applies OS-level kernel hardening (dev-sec.io)
- Installs Docker CE and the compose plugin
- Adds `deploy` to the `docker` group
- Configures UFW: allow 22, 80, 443 (TCP); 443 (UDP for HTTP/3)

## Step 7 — Verify the result

```bash
# SSH still works
ssh myserver

# Root login is now blocked:
ssh root@YOUR_SERVER_IP  # should be refused

# Docker is installed
docker --version
docker compose version

# Firewall is active
sudo ufw status
```

## Re-running and updating

The quick site playbook is safe to re-run at any time. Changes to roles or
variables will be applied on the next run:

```bash
ansible-playbook -i ansible/inventory/myserver ansible/site-quick.yml
```

To re-run the heavier first-run/compliance pass:

```bash
ansible-playbook -i ansible/inventory/myserver ansible/site-first-run.yml
```

To apply only specific roles:

```bash
# Only Docker-related tasks
ansible-playbook -i ansible/inventory/myserver ansible/site-quick.yml --tags docker

# Only hardening tasks
ansible-playbook -i ansible/inventory/myserver ansible/site-quick.yml --tags hardening
```

## Step 8 — Alerting and availability

```bash
# On the server: mint an ntfy publish token, then set it in the inventory
ssh myserver 'cd /opt/deploy && docker compose exec ntfy ntfy token add admin'
# ansible/hosts:  notify_ntfy_url=http://127.0.0.1:8080/alerts  notify_ntfy_token=tk_...

# Dead-man's switch (host-down alarm) — Gatus external endpoint or
# Healthchecks URL; see ansible/hosts.example for both dialects:
#   notify_deadman_url=...   notify_deadman_token=...   (Gatus)
ansible-playbook -i ansible/inventory/myserver ansible/site-quick.yml
```

## Step 9 — Backups, secret recovery, off-host logs

All three run from your laptop against AWS, then land via Ansible:

```bash
pip install boto3
# Backup bucket + scoped IAM user → values into backup/config.env
python3 scripts/aws-backup-setup.py --profile my-aws-admin --bucket myserver-backups --iam-user myserver-backup
# Object-locked log bucket + WRITE-ONLY IAM user → log_export_* vars into ansible/hosts
python3 scripts/aws-logs-setup.py --profile my-aws-admin --bucket myserver-logs --iam-user myserver-log-writer

# Secret recovery (the .env files exist only on the box otherwise):
cp backup/services/env-files.env.example backup/services/env-files.env
$EDITOR backup/services/env-files.env
# >>> This service's RESTIC_REPOSITORY + RESTIC_PASSWORD is the recovery root
# >>> after a total loss. You do not have to hand-copy it: Step 13 packages it
# >>> (and every other not-in-git secret) into one encrypted bundle. Do that
# >>> step — it is not optional.

ansible-playbook -i ansible/hosts scaffold/ansible/site-quick.yml
ansible-playbook -i ansible/hosts ansible/backup.yml
```

## Step 10 — Auth tier (if any app needs a login wall)

Uncomment the `apps/auth` include, create `apps/auth/.env` (keep
`TOTP_ENABLED=true` — admins get email-OTP **plus** TOTP), and guard routes
with `import protected <upstream>`. See [07-auth.md](07-auth.md).

## Step 11 — Restricted access mode (staged)

The `admin` break-glass account exists from bootstrap. Once you have verified
`ssh admin@host 'sudo -n true && docker ps'`, flip
`deploy_restricted_mode=true` + `ansible_user=admin` per the runbook in
[05-access-model.md](05-access-model.md). Reversible; retires the register's
biggest exception.

## Step 12 — Evidence baseline

```bash
# Mode-aware end-to-end smoke test. --strict also fails on a missing/stale
# recovery bundle (Step 13) or an unconfigured alerting/log-export layer:
bash scripts/post-provision-smoke-test.sh myserver --require-backup --strict
# Full audit bundle (OpenSCAP L1+L2, docker-bench, compose audit, Trivy,
# Lynis, host captures with a control-tagged INDEX):
ansible-playbook -i ansible/hosts scaffold/ansible/audit-all.yml
# Fire the timers once, eyeball their output:
ssh myserver 'sudo systemctl start vuln-scan.service restore-drill.service log-export.service'
```

Copy [templates/](templates/) into the server repo's `compliance/` directory
and fill them in — that pack plus the `reports/` bundle is what you hand a
reviewer (see [compliance-plan-vic-health.md](compliance-plan-vic-health.md)).

## Step 13 — Recovery bundle (do this last, and after any secret change)

The box is not "set-and-forget" until a total loss is survivable. Everything
NOT in git — `ansible/hosts`, the server `.env`, every `apps/*/.env`, and the
restic **repository password** (without which the offsite backups are
undecryptable) — lives only on this box. Package it into one encrypted archive:

```bash
# Run ON the server, with sudo — the restic secrets in /etc/restic are
# root-only and a laptop/non-sudo bundle silently omits them. Preview first:
ssh myserver 'cd /opt/deploy && sudo DRY_RUN=1 scripts/make-recovery-bundle.sh'
ssh -t myserver 'cd /opt/deploy && sudo scripts/make-recovery-bundle.sh'  # -t: openssl needs a TTY to read your passphrase
scp myserver:'~/recovery-bundle-*.tar.gz.enc' .                          # pull it off the box
```

Then store the **bundle** and its **passphrase** in your password manager as
two separate entries (split across two places — losing either loses
everything), and keep the bundle somewhere that survives your laptop. A
success drops a `/opt/deploy/.recovery-bundle-last` marker; the `--strict`
smoke test (Step 12) reports the bundle **stale** whenever a captured secret is
newer than it — so **re-run this after any credential rotation.** The full
rebuild drill and RTO log are in [09-recovery.md](09-recovery.md).

## Upgrading an existing instance

Scaffold changes reach instances only when you bump the submodule pointer.
The mechanics plus the **per-change operator actions** live in
[../UPGRADING.md](../UPGRADING.md) — read every entry newer than your current
pointer before re-running the site play.

---

Next: [04-server-repo.md](04-server-repo.md)
