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


def main():
    fails = 0
    for name, container, key, want in CASES:
        got = cch.evaluate(container)[key]
        if got is not want:
            fails += 1
            print(f"[FAIL] {name}: {key}={got} (want {want})")
        else:
            print(f"[OK] {name}: {key}={got}")
    print(f"\n{len(CASES) - fails}/{len(CASES)} passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
