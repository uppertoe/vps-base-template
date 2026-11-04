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


def mk(binds=None, mounts=None, capadd=None, netmode="bridge", sec=None, **host):
    return {
        "HostConfig": dict({
            "Binds": binds or [],
            "CapAdd": capadd or [],
            "NetworkMode": netmode,
            "SecurityOpt": sec if sec is not None else ["no-new-privileges:true"],
        }, **host),
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
    ("no-new-privileges:true", mk(), "no_new_privileges", True),
    ("bare no-new-privileges", mk(sec=["no-new-privileges"]), "no_new_privileges", True),
    ("no-new-privileges:false", mk(sec=["no-new-privileges:false"]), "no_new_privileges", False),
    ("true then false", mk(sec=["no-new-privileges:true", "no-new-privileges:false"]), "no_new_privileges", False),
    ("no security options", mk(sec=[]), "no_new_privileges", False),
    ("default confinement", mk(), "confined", True),
    ("seccomp unconfined", mk(sec=["no-new-privileges:true", "seccomp=unconfined"]), "confined", False),
    ("apparmor unconfined", mk(sec=["apparmor:unconfined"]), "confined", False),
    ("label disable", mk(sec=["label:disable"]), "confined", False),
    ("userns host", mk(UsernsMode="host"), "no_host_namespaces", False),
    ("pid host", mk(PidMode="host"), "no_host_namespaces", False),
    ("private namespaces", mk(), "no_host_namespaces", True),
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
        "an app shares its own members network with the gateway alone -> passes",
        {
            "caddy": netc("caddy", ["cases_proxy", "auth_proxy"], "caddy:2"),
            "cases": netc("cases", ["cases_proxy", "cases_members"]),
            "auth": netc("auth", ["auth_proxy", "cases_members", "rota_members"]),
            "rota": netc("rota", ["rota_proxy", "rota_members"]),
        },
        {
            "cases": {"proxy_network_exclusive": True, "internal_network_isolated": True},
            "rota": {"proxy_network_exclusive": True, "internal_network_isolated": True},
            "auth": {"proxy_network_exclusive": True, "internal_network_isolated": True},
        },
    ),
    (
        "a second app on another app's members network -> internal isolation fails",
        {
            "caddy": netc("caddy", ["cases_proxy", "rota_proxy", "auth_proxy"], "caddy:2"),
            "cases": netc("cases", ["cases_proxy", "cases_members"]),
            "rota": netc("rota", ["rota_proxy", "cases_members"]),
            "auth": netc("auth", ["auth_proxy", "cases_members"]),
        },
        {
            "cases": {"internal_network_isolated": False},
            "rota": {"internal_network_isolated": False},
        },
    ),
    (
        "the exemption is for the gateway only: another service named like it is not exempt elsewhere",
        {
            "caddy": netc("caddy", ["cases_proxy"], "caddy:2"),
            "cases": netc("cases", ["cases_proxy", "cases_internal"]),
            "auth": netc("auth", ["cases_internal"]),
        },
        {
            "cases": {"internal_network_isolated": False},
        },
    ),
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


# The slice is what actually keeps a user-facing app resident; being asked for it
# and not getting it is the failure mode worth a test, since Docker's
# memswap_limit silently does nothing under the systemd cgroup driver.
WEB_CASES = [
    (
        "app under the no-swap slice passes",
        {"HostConfig": {"CgroupParent": "vps-noswap.slice"}},
        True,
    ),
    (
        "app with no cgroup parent fails",
        {"HostConfig": {}},
        False,
    ),
    (
        "app under some other slice fails",
        {"HostConfig": {"CgroupParent": "system.slice"}},
        False,
    ),
]


# A container with no cgroup_parent lands in system.slice beneath no collective
# cap; the control exists so that omission is a finding rather than a silent
# landing. Any of the docker role's tiers (children of vps.slice) satisfies it.
TIER_CASES = [
    ("no-swap tier", {"HostConfig": {"CgroupParent": "vps-noswap.slice"}}, True),
    ("batch tier", {"HostConfig": {"CgroupParent": "vps-batch.slice"}}, True),
    ("data tier", {"HostConfig": {"CgroupParent": "vps-data.slice"}}, True),
    ("the parent itself", {"HostConfig": {"CgroupParent": "vps.slice"}}, True),
    ("no cgroup parent -> system.slice", {"HostConfig": {}}, False),
    ("system.slice named explicitly", {"HostConfig": {"CgroupParent": "system.slice"}}, False),
    ("look-alike outside the vps hierarchy", {"HostConfig": {"CgroupParent": "vpsdata.slice"}}, False),
    ("a nested path, not a slice name", {"HostConfig": {"CgroupParent": "vps.slice/vps-data.slice"}}, False),
]


# The static mode: a `docker compose config --format json` document is turned
# into inspect-shaped records and the same controls decide. The hardened
# service is the section 5 block every app carries; each other service drops
# one thing, and the control that notices it must be the one that fails.
HARDENED = {
    "image": "ghcr.io/x/app:1@sha256:" + "0" * 64,
    "user": "10001:10001",
    "cap_drop": ["ALL"],
    "security_opt": ["no-new-privileges:true"],
    "read_only": True,
    "mem_limit": "268435456",
    "pids_limit": 64,
    "cgroup_parent": "vps-noswap.slice",
    "healthcheck": {"test": ["CMD", "true"], "interval": "30s"},
    "volumes": [{"type": "volume", "source": "app_data", "target": "/data"}],
    "networks": {"app_proxy": None},
}


def compose_cfg(**services):
    cfg = {"services": {"caddy": dict(HARDENED, image="caddy:2.11.7-alpine", user="65531:65531",
                                      cap_add=["NET_BIND_SERVICE"], networks={"app_proxy": None})}}
    cfg["services"].update(services)
    return cfg


def without(key, **override):
    svc = {k: v for k, v in HARDENED.items() if k != key}
    svc.update(override)
    return svc


# (name, compose service, control key, expected)
STATIC_CASES = [
    ("hardened service passes every runtime control", dict(HARDENED), None, True),
    ("no cap_drop", without("cap_drop"), "cap_drop_all", False),
    ("no security_opt", without("security_opt"), "no_new_privileges", False),
    ("no-new-privileges:false", without("security_opt", security_opt=["no-new-privileges:false"]), "no_new_privileges", False),
    ("no read_only", without("read_only"), "read_only", False),
    ("no mem_limit", without("mem_limit"), "mem_limit", False),
    ("mem_limit in the deploy block", without("mem_limit", deploy={"resources": {"limits": {"memory": "67108864"}}}), "mem_limit", True),
    ("mem_limit written as 256m", without("mem_limit", mem_limit="256m"), "mem_limit", True),
    ("no pids_limit", without("pids_limit"), "pids_limit", False),
    ("root user", without("user", user="0:0"), "non_root", False),
    ("no healthcheck", without("healthcheck"), "healthcheck", False),
    ("healthcheck disabled", without("healthcheck", healthcheck={"disable": True}), "healthcheck", False),
    ("string healthcheck test", without("healthcheck", healthcheck={"test": "curl -f localhost"}), "healthcheck", True),
    ("docker.sock bind", without("volumes", volumes=[{"type": "bind", "source": "/var/run/docker.sock", "target": "/var/run/docker.sock"}]), "no_sensitive_mounts", False),
    ("short-form docker.sock bind", without("volumes", volumes=["/var/run/docker.sock:/var/run/docker.sock:ro"]), "no_sensitive_mounts", False),
    ("privileged", without("read_only", read_only=True, privileged=True), "privileged", False),
    ("cap_add SYS_ADMIN", dict(HARDENED, cap_add=["SYS_ADMIN"]), "cap_add_minimal", False),
    ("host network", dict(HARDENED, network_mode="host"), "no_host_network", False),
    ("pid host", dict(HARDENED, pid="host"), "no_host_namespaces", False),
    ("seccomp unconfined", dict(HARDENED, security_opt=["no-new-privileges:true", "seccomp:unconfined"]), "confined", False),
    ("no cgroup_parent", without("cgroup_parent"), "memory_tier", False),
    ("batch tier on a proxy network", dict(HARDENED, cgroup_parent="vps-batch.slice"), "web_no_swap", False),
    ("db with a published port", dict(HARDENED, image="postgres:18", ports=[{"target": 5432, "published": "5432", "protocol": "tcp"}]), "db_no_published_ports", False),
    ("db on a proxy network", dict(HARDENED, image="postgres:18"), "db_off_proxy_network", False),
    ("db kept off the proxy network", dict(HARDENED, image="postgres:18", networks={"app_internal": None}), "db_off_proxy_network", True),
]


def static_results(svc):
    inspected = cch.inspected_from_compose(compose_cfg(app=svc), "ci")
    c = inspected["ci-app-1"]
    results = cch.evaluate(c)
    results.update(cch.evaluate_tier(c))
    results.update(cch.evaluate_web(c))
    proxy = set(cch.container_networks(inspected["ci-caddy-1"]))
    results.update(cch.evaluate_db(c, proxy))
    results.update(cch.network_controls(inspected)["ci-app-1"])
    return results


def main():
    fails = 0
    for name, svc, key, want in STATIC_CASES:
        results = static_results(svc)
        keys = [k for _, k in cch.CONTROLS + cch.TIER_CONTROLS + cch.WEB_CONTROLS] if key is None else [key]
        for k in keys:
            got = results[k]
            if got is not want:
                fails += 1
                print(f"[FAIL] static {name}: {k}={got} (want {want})")
            else:
                print(f"[OK] static {name}: {k}={got}")

    # The exceptions register names containers as Compose does.
    named = cch.inspected_from_compose(compose_cfg(app=dict(HARDENED, container_name="my-app")), "ci")
    if set(named) != {"ci-caddy-1", "my-app"}:
        fails += 1
        print(f"[FAIL] static naming: {sorted(named)}")
    else:
        print("[OK] static naming: <project>-<service>-1, or the container_name")
    # The gateway's members network is not a peer app on the app's internal network.
    members = cch.inspected_from_compose(compose_cfg(
        app=dict(HARDENED, networks={"app_proxy": None, "app_members": None}),
        auth=dict(HARDENED, networks={"auth_proxy": None, "app_members": {"aliases": ["auth-members"]}}),
    ), "ci")
    members["ci-caddy-1"]["NetworkSettings"]["Networks"]["auth_proxy"] = {}
    isolated = cch.network_controls(members)["ci-app-1"]["internal_network_isolated"]
    if isolated is not True:
        fails += 1
        print("[FAIL] static members network: the gateway counted as a peer app")
    else:
        print("[OK] static members network: the gateway is not a peer app")

    for name, container, key, want in CASES:
        got = cch.evaluate(container)[key]
        if got is not want:
            fails += 1
            print(f"[FAIL] {name}: {key}={got} (want {want})")
        else:
            print(f"[OK] {name}: {key}={got}")

    total = len(CASES) + 2
    for name, _, key, _ in STATIC_CASES:
        total += len(cch.CONTROLS + cch.TIER_CONTROLS + cch.WEB_CONTROLS) if key is None else 1
    for name, container, want in WEB_CASES:
        total += 1
        got = cch.evaluate_web(container)["web_no_swap"]
        if got is not want:
            fails += 1
            print(f"[FAIL] {name}: web_no_swap={got} (want {want})")
        else:
            print(f"[OK] {name}: web_no_swap={got}")

    for name, container, want in TIER_CASES:
        total += 1
        got = cch.evaluate_tier(container)["memory_tier"]
        if got is not want:
            fails += 1
            print(f"[FAIL] {name}: memory_tier={got} (want {want})")
        else:
            print(f"[OK] {name}: memory_tier={got}")

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
