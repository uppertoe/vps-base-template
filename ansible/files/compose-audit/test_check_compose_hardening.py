#!/usr/bin/env python3
"""Unit checks for the runtime-audit controls that inspect synthetic
`docker inspect` output. Runs without Docker (pure logic). Exits non-zero on
any regression — wired into CI's Python checks.

Run: python3 ansible/files/compose-audit/test_check_compose_hardening.py
"""
import importlib.util
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "cch", os.path.join(_HERE, "check-compose-hardening.py")
)
cch = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cch)


def mk(binds=None, mounts=None, capadd=None, netmode="bridge"):
    return {
        "HostConfig": {
            "Binds": binds or [],
            "CapAdd": capadd or [],
            "NetworkMode": netmode,
        },
        "Mounts": mounts or [],
        "Config": {},
    }


CASES = [
    # (name, container, control_key, expected)
    ("docker.sock bind", mk(binds=["/var/run/docker.sock:/var/run/docker.sock:ro"]), "no_sensitive_mounts", False),
    ("root bind /", mk(binds=["/:/host"]), "no_sensitive_mounts", False),
    ("/etc wholesale", mk(binds=["/etc:/etc:ro"]), "no_sensitive_mounts", False),
    ("benign /etc/localtime", mk(binds=["/etc/localtime:/etc/localtime:ro"]), "no_sensitive_mounts", True),
    ("named volume", mk(binds=["caddy_data:/data"]), "no_sensitive_mounts", True),
    ("app config subpath", mk(binds=["/opt/deploy/Caddyfile:/etc/caddy/Caddyfile:ro"]), "no_sensitive_mounts", True),
    ("docker.sock via Mounts", mk(mounts=[{"Type": "bind", "Source": "/run/docker.sock"}]), "no_sensitive_mounts", False),
    ("volume-type under /var/lib/docker", mk(mounts=[{"Type": "volume", "Source": "/var/lib/docker/volumes/x/_data"}]), "no_sensitive_mounts", True),
    ("cap_add SYS_ADMIN", mk(capadd=["SYS_ADMIN"]), "cap_add_minimal", False),
    ("cap_add CAP_NET_ADMIN prefix", mk(capadd=["CAP_NET_ADMIN"]), "cap_add_minimal", False),
    ("cap_add NET_BIND_SERVICE", mk(capadd=["NET_BIND_SERVICE"]), "cap_add_minimal", True),
    ("cap_add CHOWN+DAC_OVERRIDE", mk(capadd=["CHOWN", "DAC_OVERRIDE"]), "cap_add_minimal", True),
    ("no caps", mk(), "cap_add_minimal", True),
    ("host network", mk(netmode="host"), "no_host_network", False),
    ("bridge network", mk(netmode="bridge"), "no_host_network", True),
]


def netc(service, networks, image="app:1"):
    """Synthetic inspected container for network-topology tests."""
    return {
        "HostConfig": {},
        "Mounts": [],
        "Config": {
            "Image": image,
            "Labels": {"com.docker.compose.service": service},
        },
        "NetworkSettings": {"Networks": {n: {} for n in networks}},
    }


# (name, {container_name: container}, expected {name: {key: bool}})
NET_CASES = [
    (
        "healthy estate: each app on its own proxy net, planka+db on planka_internal",
        {
            "caddy": netc("caddy", ["planka_proxy", "auth_proxy"], "caddy:2"),
            "planka": netc("planka", ["planka_proxy", "planka_internal"]),
            "planka-db": netc("planka-db", ["planka_internal"], "postgres:18-alpine"),
            "auth": netc("auth", ["auth_proxy"]),
        },
        {
            "planka": {"proxy_network_exclusive": True, "internal_network_isolated": True},
            "planka-db": {"proxy_network_exclusive": True, "internal_network_isolated": True},
            "auth": {"proxy_network_exclusive": True, "internal_network_isolated": True},
        },
    ),
    (
        # The bug this control exists for: the invite portal put on Planka's
        # internal network can forge Remote-* straight to the Planka app.
        "portal shares planka_internal with the planka app -> internal isolation fails",
        {
            "caddy": netc("caddy", ["planka_proxy", "invite_proxy"], "caddy:2"),
            "planka": netc("planka", ["planka_proxy", "planka_internal"]),
            "planka-db": netc("planka-db", ["planka_internal"], "postgres:18-alpine"),
            "invite": netc("invite", ["invite_proxy", "planka_internal"]),
        },
        {
            "planka": {"internal_network_isolated": False},
            "invite": {"internal_network_isolated": False},
            "planka-db": {"internal_network_isolated": False},
        },
    ),
    (
        # The fix: a dedicated db-only network. Portal reaches the db; no app
        # peer shares an internal network.
        "portal on a dedicated invite_db with only planka-db -> passes",
        {
            "caddy": netc("caddy", ["planka_proxy", "invite_proxy"], "caddy:2"),
            "planka": netc("planka", ["planka_proxy", "planka_internal"]),
            "planka-db": netc("planka-db", ["planka_internal", "invite_db"], "postgres:18-alpine"),
            "invite": netc("invite", ["invite_proxy", "invite_db"]),
        },
        {
            "planka": {"internal_network_isolated": True},
            "invite": {"internal_network_isolated": True},
        },
    ),
    (
        "two apps share a proxy network -> proxy exclusivity fails",
        {
            "caddy": netc("caddy", ["shared_proxy"], "caddy:2"),
            "a": netc("a", ["shared_proxy"]),
            "b": netc("b", ["shared_proxy"]),
        },
        {
            "a": {"proxy_network_exclusive": False},
            "b": {"proxy_network_exclusive": False},
        },
    ),
]


def main():
    fails = 0
    for name, container, key, want in CASES:
        got = cch.evaluate(container)[key]
        if got is not want:
            fails += 1
            print(f"[FAIL] {name}: {key}={got} (want {want})")
        else:
            print(f"[OK] {name}: {key}={got}")

    total = len(CASES)
    for name, inspected, expected in NET_CASES:
        got = cch.network_controls(inspected)
        for cname, keys in expected.items():
            for key, want in keys.items():
                total += 1
                actual = got.get(cname, {}).get(key)
                if actual is not want:
                    fails += 1
                    print(f"[FAIL] {name}: {cname}.{key}={actual} (want {want})")
                else:
                    print(f"[OK] {name}: {cname}.{key}={actual}")

    print(f"\n{total - fails}/{total} passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
