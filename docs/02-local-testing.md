# Local Testing

Two test layers cover different things:

| Layer | What it tests | Tool |
|-------|---------------|------|
| Molecule `default` | All roles deploy correctly on Ubuntu + Debian | Molecule + Docker |
| Molecule `backup` | Backup role deploys scripts/config with correct permissions | Molecule + Docker |
| Integration tests | `backup.sh` and `restore.sh` actually work end-to-end | Bash + Docker |

---

## Molecule — role deployment tests

Molecule tests the Ansible roles against real containerised OS images before
running anything on a real server. No VPS needed.

### What the `default` scenario covers

Runs all roles against **Ubuntu 24.04** and **Debian 12** and verifies:
- The `deploy` user exists with the correct SSH key and sudo access
- The deployed SSH key matches the configured `ansible_ssh_private_key_file`
- `authorized_keys`, sudoers, and the deploy helper script have the expected ownership and permissions
- SSH password authentication is disabled
- Root SSH login is disabled and SSH is restricted to `deploy`
- Docker and the compose plugin are installed
- The deploy user is in the `docker` group
- UFW is active and exposes exactly the expected ports
- `/opt/deploy` exists and is owned by `deploy`

> **Container limitations:** Kernel-level hardening (sysctl settings from
> `os_hardening`) is skipped inside Docker containers — those changes require
> a real kernel. Docker-in-Docker is also skipped — the Docker role installs
> Docker but doesn't start the daemon.

### Running the default scenario

```bash
# Full test run (create → converge → verify → destroy)
molecule test

# Step through manually (useful for debugging)
molecule create
molecule converge
molecule verify
molecule destroy

# Re-run without recreating containers
molecule converge && molecule verify

# Log in to a container for inspection
molecule login --host ubuntu-2404
```

### Targeting a single distro

```bash
molecule test -- -l ubuntu-2404
molecule test -- -l debian-12
```

### What the `backup` scenario covers

Tests the backup role in isolation (single Ubuntu container):
- `backup.sh` and `restore.sh` installed at `/opt/backup/` with correct permissions
- Config files at `/etc/restic/` with mode 0600
- Backup and backup-verify systemd units installed
- restic binary present and executable
- Scripts reject bad arguments (syntax smoke test)

### Running the backup scenario

```bash
molecule test -s backup

# Or step through:
molecule converge -s backup
molecule verify -s backup
```

### Verbose output

```bash
molecule converge -- -v      # verbose
molecule converge -- -vvv    # very verbose
```

### Troubleshooting

**`cgroups` error on first run**

```bash
# Docker Desktop → Settings → General
# Enable "Use Virtualization framework" and "Use Rosetta for x86/amd64..."
# Then restart Docker Desktop
```

**`image not found` or pull errors**

```bash
docker pull geerlingguy/docker-ubuntu2404-ansible:latest
docker pull geerlingguy/docker-debian12-ansible:latest
```

**A verify assertion fails**

Run `molecule login --host ubuntu-2404` to inspect the container. The container
persists between `converge` and `verify`.

---

## Integration tests — backup + restore end-to-end

Tests that the backup and restore scripts work correctly against a real
PostgreSQL database and a local restic repository.

### Prerequisites

```bash
# macOS
brew install restic

# Debian/Ubuntu
apt install restic
```

Docker must be running. All database operations run via `docker exec` into the
PostgreSQL container — no system `psql` or `pg_dump` required.

### Running the tests

```bash
cd vps-base-template
bash backup/tests/integration/run_tests.sh
```

### What gets tested

| Test | What it validates |
|------|------------------|
| `test_dry_run_exits_zero` | `--dry-run` makes no changes, exits 0 |
| `test_backup_creates_snapshot` | A snapshot exists after backup |
| `test_retention_runs_clean` | `forget --prune` runs without error |
| `test_restore_into_alternate_db` | Rows match after restore to a different DB |
| `test_verify_passes` | Built-in table count check passes after good restore |
| `test_restore_rollback_on_failure` | Original DB is preserved when restore fails |
| `test_partial_failure_continues` | A bad service fails; other services still back up |
| `test_optional_service_skips_stopped_container` | `OPTIONAL=true` skips gracefully, exits 0 |
| `test_list_snapshots` | `--list` shows snapshots for a service |

The `test_restore_rollback_on_failure` and `test_partial_failure_continues`
tests are the most important — they validate the reliability fixes in the
backup scripts (rollback on failure, per-service failure accumulation).

---

Next: [03-provisioning-a-server.md](03-provisioning-a-server.md)
