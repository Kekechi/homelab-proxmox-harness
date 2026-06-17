#!/usr/bin/env python3
"""
test-golden.py — Golden-output regression test for generate-configs.py

Renders every pure emitter against ONE complete, synthetic fixture config dict
(no secrets, no committed config/*.yml) and byte-compares the result to a
committed golden file under scripts/golden/. This is the regression net for the
generator: any change to emitted tfvars / inventory / allowed-cidrs / env.mk /
PKI group_vars output is caught immediately, which makes refactors (e.g. the
genconfig modularization) safe to verify by "golden output is unchanged".

It deliberately tests the emitters' RETURN VALUES, not the file-writing path, so
it sidesteps the .envrc smart-merge nondeterminism (L11).

Usage:
  python3 scripts/test-golden.py            # compare against golden files
  python3 scripts/test-golden.py --update   # regenerate golden files (review the diff!)
"""

import sys
import os
import importlib.util

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GEN_PATH = os.path.join(REPO_ROOT, "scripts", "generate-configs.py")
GOLDEN_DIR = os.path.join(REPO_ROOT, "scripts", "golden")

spec = importlib.util.spec_from_file_location("gen", GEN_PATH)
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)

# ---------------------------------------------------------------------------
# One complete fixture exercising every service + cross-service derivation.
# Synthetic values only (RFC5737/RFC1918 test addresses, example.com).
# ---------------------------------------------------------------------------
FIXTURE = {
    "environment": "sandbox",
    "domain_name": "lab.example.com",
    "ssh": {"public_key": "ssh-ed25519 AAAATESTKEY golden", "default_user": "ubuntu"},
    "infrastructure": {
        "dns_server": "10.20.0.2",
        "proxmox": {"ip": "10.20.0.1", "port": 8006, "insecure": True},
        "nodes": {"n1": {"ip": "10.20.0.1"}},
        "networks": {
            "lab": {"bridge": "labbr", "cidr": "10.20.30.0/24", "gateway": "10.20.30.1", "vlan_id": None},
        },
        "default_network": "lab",
        "storage": {
            "datastore_id": "disk0",
            "cloudinit_datastore_id": "disk0",
            "lxc_template_file_id": "tmpl:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst",
        },
    },
    "terraform": {
        "pool_id": "golden-pool",
        "vm_id_range_start": 300,
        "state_bucket": "tfstate-sandbox",
    },
    "services": {
        "minio": {"node": "n1", "ip": "10.20.30.10", "port": 9000, "ansible_user": "root",
                  "hostname": "minio-server", "fqdn": "minio.lab.example.com", "tls": False, "network": "lab"},
        "pki": {
            "root_ca": {"node": "n1", "ip": "10.20.30.11/24", "vm_id": 311, "ansible_user": "debian",
                        "hostname": "root-ca", "cloud_init_template_id": 9000,
                        "cloud_init_template_node": "n1", "dns": False, "network": "lab"},
            "issuing_ca": {"node": "n1", "ip": "10.20.30.12/24", "ct_id": 312, "ansible_user": "root",
                           "hostname": "issuing-ca", "dns_name": "ca", "network": "lab"},
        },
        "dns": {
            "auth": {"node": "n1", "ip": "10.20.30.13/24", "ct_id": 313, "ansible_user": "root",
                     "hostname": "dns-auth", "network": "lab"},
            "dist": {"node": "n1", "ip": "10.20.30.14/24", "ct_id": 314, "ansible_user": "root",
                     "hostname": "dns-dist", "network": "lab", "client_cidrs": ["10.20.10.0/24"]},
        },
        "nexus": {"node": "n1", "ip": "10.20.30.15/24", "ct_id": 315, "ansible_user": "root",
                  "hostname": "nexus-server", "fqdn": "nexus.lab.example.com", "network": "lab"},
        "log_server": {"enabled": True, "node": "n1", "ip": "10.20.30.16/24", "ct_id": 316,
                       "ansible_user": "root", "hostname": "log-server", "network": "lab"},
        "splunk": {"enabled": False, "node": "n1", "ip": "10.20.30.17/24", "vm_id": 317,
                   "ansible_user": "ubuntu", "hostname": "splunk-server", "fqdn": "splunk.lab.example.com",
                   "tls": True, "cloud_init_template_id": 9002, "network": "lab"},
    },
}

ENV = "sandbox"


def _emitters():
    """name -> rendered string. PKI group_vars returns a tuple → split into two."""
    out = {
        "tfvars": gen.gen_tfvars(FIXTURE, ENV),
        "inventory": gen.gen_inventory(FIXTURE, ENV),
        "allowed_cidrs": gen.gen_allowed_cidrs(FIXTURE, ENV),
        "env_mk": gen.gen_env_mk(FIXTURE, ENV),
        "envrc": gen.gen_envrc(FIXTURE, ENV),
    }
    root_ca_vars, issuing_ca_vars = gen.gen_pki_group_vars(FIXTURE, ENV)
    out["pki_root_ca_vars"] = root_ca_vars
    out["pki_issuing_ca_vars"] = issuing_ca_vars
    return out


def main():
    update = "--update" in sys.argv
    os.makedirs(GOLDEN_DIR, exist_ok=True)
    rendered = _emitters()
    failures = []
    for name, content in sorted(rendered.items()):
        path = os.path.join(GOLDEN_DIR, f"{name}.golden")
        if update:
            with open(path, "w") as f:
                f.write(content)
            print(f"  updated {name}.golden ({len(content)} bytes)")
            continue
        if not os.path.exists(path):
            failures.append(f"{name}: golden file missing ({path}). Run with --update.")
            continue
        with open(path) as f:
            expected = f.read()
        if content != expected:
            failures.append(f"{name}: output differs from golden (run --update to inspect the diff)")

    if update:
        print("Golden files updated. Review `git diff scripts/golden/` before committing.")
        return 0
    if failures:
        print("GOLDEN TEST FAILED:")
        for fmsg in failures:
            print("  -", fmsg)
        return 1
    print(f"GOLDEN TEST PASSED ({len(rendered)} emitters match)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
