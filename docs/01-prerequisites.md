# Prerequisites

Everything you need on your local machine before provisioning a server.

## 1. SSH key pair

Ansible connects to your server over SSH using a key pair. If you don't have one:

```bash
# Generate an Ed25519 key (preferred — smaller, faster, more secure than RSA)
ssh-keygen -t ed25519 -C "your@email.com"

# Accept the default path (~/.ssh/id_ed25519) or specify one
# Set a passphrase — you'll be prompted once per session by ssh-agent
```

This creates two files:
- `~/.ssh/id_ed25519` — **private key**, never share this
- `~/.ssh/id_ed25519.pub` — **public key**, this goes on the server

To print your public key (you'll need this when creating a VPS):

```bash
cat ~/.ssh/id_ed25519.pub
```

### Adding your key to ssh-agent (so you're not asked for the passphrase repeatedly)

```bash
# Start ssh-agent if not running
eval "$(ssh-agent -s)"

# Add your key
ssh-add ~/.ssh/id_ed25519
```

On macOS, add this to your `~/.zshrc` or `~/.bash_profile` to persist across
sessions:

```bash
# ~/.zshrc
ssh-add --apple-use-keychain ~/.ssh/id_ed25519 2>/dev/null
```

## 2. Python 3

Ansible requires Python 3 on your local machine (the "control node").

```bash
# Check if installed
python3 --version

# Install via Homebrew if not present
brew install python3
```

## 3. Ansible

```bash
pip3 install --user ansible

# Verify
ansible --version
```

> **Note:** If `ansible` is not found after install, your user bin directory
> may not be on your PATH. Add it:
> ```bash
> echo 'export PATH="$HOME/Library/Python/$(python3 -c "import sys; print(f\"{sys.version_info.major}.{sys.version_info.minor}\")")/bin:$PATH"' >> ~/.zshrc
> source ~/.zshrc
> ```

## 4. Install Ansible Galaxy dependencies

From the root of this repo:

```bash
ansible-galaxy collection install -r ansible/requirements.yml
```

This installs the `devsec.hardening` and `community.general` collections that
the roles depend on.

## 5. Docker Desktop (for local testing)

Required to run the Molecule test suite. Download from:
https://www.docker.com/products/docker-desktop/

After install, ensure Docker is running:

```bash
docker info
```

## 6. Molecule (for local testing)

```bash
pip3 install --user molecule molecule-plugins[docker]

# Verify
molecule --version
```

## 7. Set up your local SSH config (optional but recommended)

Add an entry to `~/.ssh/config` for each server so you can `ssh myserver`
instead of `ssh deploy@1.2.3.4`:

```
Host myserver
    HostName 1.2.3.4
    User deploy
    IdentityFile ~/.ssh/id_ed25519
```

---

Next: [02-local-testing.md](02-local-testing.md)
