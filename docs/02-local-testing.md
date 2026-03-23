# Local Testing with Molecule

Molecule lets you test the Ansible roles against real (containerised) OS images
before running anything on a real server. Runs entirely on your local machine
via Docker — no VPS needed.

## What gets tested

The test suite runs all roles against:
- **Ubuntu 24.04** (primary target)
- **Debian 12**

It verifies that after the playbook runs:
- The `deploy` user exists with the correct SSH key and sudo access
- SSH password authentication is disabled
- Docker and the compose plugin are installed
- The deploy user is in the `docker` group
- UFW is active
- `/opt/deploy` exists and is owned by `deploy`

> **Container limitations:** Kernel-level hardening (sysctl settings from
> `os_hardening`) is skipped inside Docker containers — those changes require
> a real kernel. They're tested by the devsec.io project's own test suite and
> are applied on real servers. Docker-in-Docker is also skipped — the Docker
> role installs Docker but doesn't start the daemon.

## Running the tests

From the root of this repo:

```bash
# Full test run (create → converge → verify → destroy)
molecule test

# Step through manually (useful for debugging)
molecule create       # start containers
molecule converge    # apply the playbook
molecule verify      # run assertions
molecule destroy     # tear down containers

# Re-run converge without recreating containers (fast iteration)
molecule converge
molecule verify

# Log in to a container for manual inspection
molecule login --host ubuntu-2404
```

## Targeting a single distro

```bash
# Run against Ubuntu only
molecule test -- -l ubuntu-2404

# Run against Debian only
molecule test -- -l debian-12
```

## Running with verbose Ansible output

```bash
molecule converge -- -v      # verbose
molecule converge -- -vvv    # very verbose (shows all task details)
```

## Troubleshooting

**`cgroups` error on first run**

Some macOS + Docker Desktop combinations have cgroup issues. Try:

```bash
# In Docker Desktop → Settings → General
# Enable "Use Virtualization framework" and "Use Rosetta for x86/amd64..."
# Then restart Docker Desktop
```

**`image not found` or pull errors**

The images are pulled from Docker Hub on first run. Ensure Docker Desktop is
running and you have internet access:

```bash
docker pull geerlingguy/docker-ubuntu2404-ansible:latest
docker pull geerlingguy/docker-debian12-ansible:latest
```

**Molecule can't find roles**

The `ANSIBLE_ROLES_PATH` is set in `molecule/default/molecule.yml`. If you
move the molecule directory, update that path.

**A verify assertion fails**

Run `molecule login --host ubuntu-2404` to inspect the container and debug
manually. The container persists between `converge` and `verify` steps.

## Adding tests

Edit `molecule/default/verify.yml`. Tests are written as regular Ansible tasks
with `ansible.builtin.assert`. Follow the pattern of existing checks: gather
facts/files with a task, then assert on the result.

---

Next: [03-provisioning-a-server.md](03-provisioning-a-server.md)
