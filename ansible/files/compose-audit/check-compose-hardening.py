#!/usr/bin/env python3
"""Assert CIS Docker Benchmark section 5 (container runtime) controls against the
running stack.

docker-bench-security checks the daemon (sections 1-4); nothing in the scaffold
verified the per-container §5 controls that the compose files declare. This does:
it inspects every running container and checks the controls the scaffold expects
every app to carry, then prints docker-bench-style [PASS]/[WARN] lines and writes
a JSON + Markdown report.

Usage:
  check-compose-hardening.py [--json OUT.json] [--md OUT.md] [--exceptions FILE]

Exit code: 0 if every (non-excepted) control passes, 1 otherwise — so the audit
playbook fails loudly on a regression.
"""
import argparse
import json
import subprocess
import sys

# CIS Docker Benchmark §5 controls we assert from `docker inspect`.
CONTROLS = [
    ("5.4 not privileged", "privileged"),
    ("5.3 cap_drop ALL", "cap_drop_all"),
    ("5.25 no-new-privileges", "no_new_privileges"),
    ("5.12 read-only rootfs", "read_only"),
    ("5.10 memory limit", "mem_limit"),
    ("5.28 pids limit", "pids_limit"),
    ("5.x non-root user", "non_root"),
    ("5.26 healthcheck", "healthcheck"),
    ("5.31 no docker.sock / sensitive host mounts", "no_sensitive_mounts"),
    ("5.3 minimal cap_add (allowlist)", "cap_add_minimal"),
    ("5.9 no host network namespace", "no_host_network"),
]

INIT_CONTROLS = [
    ("5.4 init: not privileged", "privileged"),
    ("5.3 init: cap_drop ALL", "cap_drop_all"),
    ("5.25 init: no-new-privileges", "no_new_privileges"),
    ("5.12 init: read-only rootfs", "read_only"),
    ("5.10 init: memory limit", "mem_limit"),
    ("5.28 init: pids limit", "pids_limit"),
    ("scaffold init: no network", "network_none"),
    ("5.31 init: no sensitive host mounts", "no_sensitive_mounts"),
    ("5.3 init: minimal cap_add", "cap_add_minimal"),
]

# CIS 5.31 / host-fs escapes: a bind of the Docker socket (full daemon = host
# root) or of a top-level system directory turns cap_drop/read-only into
# theatre. Exact-root match only — a benign subpath bind like
# /etc/localtime:ro or an app data dir under /srv is NOT flagged; wholesale
# roots are. Read-only does not help: a ro docker.sock still drives the API,
# a ro / still leaks every host secret.
SENSITIVE_BIND_ROOTS = {
    "/", "/etc", "/proc", "/sys", "/dev", "/boot", "/root", "/home",
    "/run", "/var/run", "/var/lib/docker", "/usr", "/bin", "/sbin", "/lib",
}

# CIS 5.3: with cap_drop ALL, the only capabilities an app may add back. Init
# volume-owners need CHOWN/DAC_OVERRIDE; Caddy needs NET_BIND_SERVICE. Anything
# else (SYS_ADMIN, NET_ADMIN, SYS_PTRACE, DAC_READ_SEARCH, …) alongside a
# cap_drop ALL is the classic "looks hardened, isn't" pattern.
ALLOWED_CAP_ADD = {
    "CHOWN", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID", "NET_BIND_SERVICE",
}


def _is_sensitive_source(src):
    if not src.startswith("/"):
        return False  # named volume, not a host path
    norm = src.rstrip("/") or "/"
    if norm.rsplit("/", 1)[-1] == "docker.sock":
        return True
    return norm in SENSITIVE_BIND_ROOTS


def sensitive_mounts(c):
    """Host-path bind sources that must never be mounted. Named volumes and
    benign subpath binds are ignored; only docker.sock and top-level system
    directories are flagged."""
    host = c.get("HostConfig") or {}
    bad = []
    for b in host.get("Binds") or []:
        # "src:dst[:mode]" — src is everything before the first colon.
        if _is_sensitive_source(b.split(":", 1)[0]):
            bad.append(b)
    for m in c.get("Mounts") or []:
        if m.get("Type") == "bind" and _is_sensitive_source(m.get("Source", "")):
            bad.append(m.get("Source", ""))
    return bad


def cap_add_ok(c):
    host = c.get("HostConfig") or {}
    added = [x.upper().replace("CAP_", "") for x in (host.get("CapAdd") or [])]
    return all(cap in ALLOWED_CAP_ADD for cap in added)

# Data-tier separation (ISM-1269/1270/1271): a database container must not be
# reachable except from its own app — no published host ports, and never on
# a reverse-proxy network where Caddy can reach it.
DB_IMAGE_MARKERS = ("postgres", "mysql", "mariadb", "mongo", "redis", "valkey")
DB_CONTROLS = [
    ("ISM-1271 db: no published ports", "db_no_published_ports"),
    ("ISM-1270 db: off reverse-proxy networks", "db_off_proxy_network"),
]

# App isolation: each Caddy-reachable (proxy) network must contain exactly one
# app container. Two apps on one proxy network can reach each other's backends
# directly and forge the Remote-* identity headers, bypassing forward_auth.
# The scaffold generates exclusive per-app networks (render-caddy-routes.sh);
# this asserts nothing reintroduced a shared one. Document deliberate pairs in
# the exceptions file.
PROXY_CONTROLS = [
    ("scaffold app: sole app on its proxy networks", "proxy_network_exclusive"),
]

# Internal-tier isolation: a NON-proxy (internal) network is meant to connect
# ONE app to its own database tier and nothing else. Two apps sharing an
# internal network can reach each other's backends directly and forge the
# Remote-* identity headers, bypassing forward_auth — exactly the risk
# proxy_network_exclusive guards against, but on a network Caddy is NOT on, so
# that check never examines it (its blind spot). DB-image containers on the
# network don't count as apps (a shared db tier is the whole point); the
# invariant is at most one NON-db app per internal network. Document a
# deliberate multi-app internal network in the exceptions file.
INTERNAL_NET_CONTROLS = [
    ("scaffold app: sole app on its internal networks", "internal_network_isolated"),
]


def is_db_container(c):
    image = ((c.get("Config") or {}).get("Image") or "").lower()
    base = image.split("@")[0].rsplit(":", 1)[0].rsplit("/", 1)[-1]
    return any(m in base for m in DB_IMAGE_MARKERS)


def evaluate_db(c, proxy_networks):
    host = c.get("HostConfig") or {}
    bindings = host.get("PortBindings") or {}
    published = any(v for v in bindings.values())
    networks = set(((c.get("NetworkSettings") or {}).get("Networks") or {}).keys())
    return {
        "db_no_published_ports": not published,
        "db_off_proxy_network": not (networks & proxy_networks),
    }


def docker(args):
    return subprocess.run(
        ["docker", *args], capture_output=True, text=True, check=True
    ).stdout


def image_user(image):
    """Effective USER baked into the image (for containers that don't override it)."""
    try:
        out = docker(["image", "inspect", image])
        return (json.loads(out)[0].get("Config") or {}).get("User", "") or ""
    except Exception:
        return ""


def is_root(user):
    u = (user or "").split(":")[0].strip()
    return u in ("", "0", "root")


def evaluate(c):
    host = c.get("HostConfig") or {}
    cfg = c.get("Config") or {}
    sec = host.get("SecurityOpt") or []
    cap_drop = [x.upper() for x in (host.get("CapDrop") or [])]
    user = cfg.get("User") or image_user(cfg.get("Image", ""))
    hc = cfg.get("Healthcheck") or {}
    hc_test = hc.get("Test") or []

    return {
        "privileged": not host.get("Privileged", False),
        "cap_drop_all": "ALL" in cap_drop,
        "no_new_privileges": any("no-new-privileges" in s for s in sec),
        "read_only": bool(host.get("ReadonlyRootfs", False)),
        "mem_limit": (host.get("Memory") or 0) > 0,
        "pids_limit": (host.get("PidsLimit") or 0) > 0,
        "non_root": not is_root(user),
        "healthcheck": len([t for t in hc_test if t not in ("", "NONE")]) > 0,
        "network_none": host.get("NetworkMode") == "none",
        "no_sensitive_mounts": not sensitive_mounts(c),
        "cap_add_minimal": cap_add_ok(c),
        "no_host_network": host.get("NetworkMode") != "host",
    }


def is_init_container(c):
    labels = ((c.get("Config") or {}).get("Labels") or {})
    return labels.get("vps-scaffold.audit") == "init-volume-owner"


def compose_service(c):
    labels = ((c.get("Config") or {}).get("Labels") or {})
    return labels.get("com.docker.compose.service")


def container_networks(c):
    return set(((c.get("NetworkSettings") or {}).get("Networks") or {}).keys())


def network_controls(inspected):
    """Cross-container network-topology controls (pure — no docker calls).

    Given {name: inspected_container}, returns {name: {control_key: bool}} for
    every app container (Caddy and one-shot init containers excluded):

    - proxy_network_exclusive: no Caddy-reachable (proxy) network this app is
      on also carries another app container.
    - internal_network_isolated: no NON-proxy (internal) network this app is on
      carries another NON-db app container.

    Both defend the same invariant (an app's peers on a shared network can
    forge Remote-* past forward_auth) on the two network classes.
    """
    proxy_networks = set()
    for c in inspected.values():
        if compose_service(c) == "caddy":
            proxy_networks.update(container_networks(c))

    # apps_per_net counts every app container (db included) — for the proxy
    # check, where a shared proxy network is always wrong. nondb_apps_per_net
    # excludes db images — for the internal check, where an app sharing a
    # network with its OWN db tier is expected and fine.
    apps_per_net = {}
    nondb_apps_per_net = {}
    for c in inspected.values():
        if compose_service(c) == "caddy" or is_init_container(c):
            continue
        for net in container_networks(c):
            apps_per_net[net] = apps_per_net.get(net, 0) + 1
            if not is_db_container(c):
                nondb_apps_per_net[net] = nondb_apps_per_net.get(net, 0) + 1

    out = {}
    for name, c in inspected.items():
        if compose_service(c) == "caddy" or is_init_container(c):
            continue
        nets = container_networks(c)
        out[name] = {
            "proxy_network_exclusive": not any(
                apps_per_net.get(net, 0) > 1 for net in nets & proxy_networks
            ),
            "internal_network_isolated": not any(
                nondb_apps_per_net.get(net, 0) > 1 for net in nets - proxy_networks
            ),
        }
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json")
    ap.add_argument("--md")
    ap.add_argument("--compose-project", help="Only audit containers from this Compose project")
    ap.add_argument(
        "--exceptions",
        help="JSON: {container_name: [control_key, ...]} to accept as documented exceptions",
    )
    args = ap.parse_args()

    exceptions = {}
    if args.exceptions:
        with open(args.exceptions) as fh:
            exceptions = json.load(fh)

    ps_args = ["ps", "-a", "--format", "{{.Names}}"]
    if args.compose_project:
        ps_args[2:2] = ["--filter", f"label=com.docker.compose.project={args.compose_project}"]
    names = [n for n in docker(ps_args).splitlines() if n]
    report = {"containers": {}, "summary": {"pass": 0, "warn": 0, "excepted": 0}}
    failed = False

    if not names:
        print("[INFO] no running containers to audit")

    inspected = {name: json.loads(docker(["inspect", name]))[0] for name in names}
    proxy_networks = set()
    for c in inspected.values():
        if compose_service(c) == "caddy":
            proxy_networks.update(container_networks(c))

    # Cross-container network-topology controls (proxy + internal isolation).
    net_controls = network_controls(inspected)

    for name in names:
        c = inspected[name]
        results = evaluate(c)
        controls = list(INIT_CONTROLS if is_init_container(c) else CONTROLS)
        if not is_init_container(c) and compose_service(c) != "caddy":
            results.update(net_controls[name])
            controls += PROXY_CONTROLS + INTERNAL_NET_CONTROLS
        if is_db_container(c):
            results.update(evaluate_db(c, proxy_networks))
            controls += DB_CONTROLS
        excepted = set(exceptions.get(name, []))
        report["containers"][name] = {}
        for label, key in controls:
            ok = results[key]
            if ok:
                status = "PASS"
                report["summary"]["pass"] += 1
            elif key in excepted:
                status = "EXCEPTED"
                report["summary"]["excepted"] += 1
            else:
                status = "WARN"
                report["summary"]["warn"] += 1
                failed = True
            report["containers"][name][key] = status
            print(f"[{status}] {name}: {label}")

    s = report["summary"]
    print(f"\nSummary: {s['pass']} pass, {s['warn']} warn, {s['excepted']} excepted")

    if args.json:
        with open(args.json, "w") as fh:
            json.dump(report, fh, indent=2)
    if args.md:
        with open(args.md, "w") as fh:
            fh.write("# Container runtime (CIS Docker §5) audit\n\n")
            fh.write(f"{s['pass']} pass, {s['warn']} warn, {s['excepted']} excepted\n\n")
            cols = []
            for _, k in CONTROLS + INIT_CONTROLS + PROXY_CONTROLS + INTERNAL_NET_CONTROLS + DB_CONTROLS:
                if k not in cols:
                    cols.append(k)
            fh.write("| container | " + " | ".join(cols) + " |\n")
            fh.write("|" + "---|" * (len(cols) + 1) + "\n")
            for name, res in report["containers"].items():
                fh.write(
                    f"| {name} | "
                    + " | ".join(res.get(k, "-") for k in cols)
                    + " |\n"
                )

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
