# Provisioning a Server

A full walkthrough from creating a VPS to a hardened, Docker-ready server.

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
ansible-galaxy collection install -r ansible/requirements.yml
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

---

Next: [04-server-repo.md](04-server-repo.md)
