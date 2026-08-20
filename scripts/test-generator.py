#!/usr/bin/env python3
"""
test-generator.py — Comprehensive tests for generate-configs.py

Tests are grouped into:
  - Validation errors (generator must exit 1 with a clear message)
  - Output content (generator must produce correct tfvars / inventory / Squid allowlist)

Usage:
  python3 scripts/test-generator.py
  python3 scripts/test-generator.py -v        # verbose
"""

import sys
import os
import importlib.util
import io
import unittest

# ---------------------------------------------------------------------------
# Load the generator module without running main()
# ---------------------------------------------------------------------------

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GEN_PATH  = os.path.join(REPO_ROOT, "scripts", "generate-configs.py")

spec = importlib.util.spec_from_file_location("gen", GEN_PATH)
gen  = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

BASE_INFRA = {
    "proxmox": {"ip": "10.0.0.1", "port": 8006, "insecure": True},
    "nodes": {
        "pve": {"ip": "10.0.0.1"},
    },
    "networks": {
        "lab": {
            "bridge": "lab",
            "cidr":    "10.10.40.0/24",
            "gateway": "10.10.40.1",
            "vlan_id": None,
        }
    },
    "default_network": "lab",
    "storage": {
        "datastore_id":           "local-lvm",
        "cloudinit_datastore_id": "local",
        "lxc_template_file_id":   "local:vztmpl/debian-12.tar.xz",
    },
}

BASE_TERRAFORM = {
    "pool_id":            "sandbox",
    "vm_id_range_start":  200,
    "clone_template_id":  0,
    "state_bucket":       "tfstate-sandbox",
}

BASE_SSH = {
    "public_key":   "ssh-ed25519 AAAA test-key",
    "default_user": "ubuntu",
}

BASE_MINIO = {
    "network":      "lab",
    "node":         "pve",
    "ip":           "10.10.40.5",
    "port":         9000,
    "ansible_user": "root",
    "hostname":     "minio",
    "fqdn":         "minio.example.com",
    "tls":          False,
}

BASE_PKI = {
    "enabled": True,
    "root_ca": {
        "node":                  "pve",
        "ip":                    "10.10.40.10/24",
        "vm_id":                 201,
        "ansible_user":          "debian",
        "hostname":              "root-ca",
        "cloud_init_template_id": 9000,
    },
    "issuing_ca": {
        "node":                  "pve",
        "ip":                    "10.10.40.11/24",
        "ct_id":                 202,
        "ansible_user":          "root",
        "hostname":              "issuing-ca",
    },
}

BASE_DNS = {
    "enabled": True,
    "auth": {
        "node":         "pve",
        "ip":           "10.10.40.12/24",
        "ct_id":        203,
        "ansible_user": "root",
        "hostname":     "dns-auth",
    },
    "dist": {
        "node":         "pve",
        "ip":           "10.10.40.13/24",
        "ct_id":        204,
        "ansible_user": "root",
        "hostname":     "dns-dist",
        "client_cidrs": ["10.10.10.0/24"],
    },
}


BASE_NEXUS = {
    "enabled":      True,
    "node":         "pve",
    "ip":           "10.10.40.14/24",
    "ct_id":        205,
    "ansible_user": "root",
    "hostname":     "nexus",
    "network":      "lab",
    # the IaC-required repo set (validate_nexus_apt_proxy_repos enforces it)
    "apt_proxy_repos": [
        {"name": "apt-proxy-trixie", "remote_url": "http://deb.example.org/debian", "distribution": "trixie"},
        {"name": "apt-proxy-trixie-security", "remote_url": "http://sec.example.org/debian-security", "distribution": "trixie-security"},
        {"name": "apt-proxy-trixie-updates", "remote_url": "http://deb.example.org/debian", "distribution": "trixie-updates"},
        {"name": "apt-proxy-smallstep", "remote_url": "https://pkg.example.org/stable/debian", "distribution": "debs", "flat": True},
        {"name": "apt-proxy-powerdns-auth-50", "remote_url": "https://repo.example.org/debian", "distribution": "trixie-auth-50"},
        {"name": "apt-proxy-powerdns-rec-54", "remote_url": "https://repo.example.org/debian", "distribution": "trixie-rec-54"},
        {"name": "apt-proxy-dnsdist-21", "remote_url": "https://repo.example.org/debian", "distribution": "trixie-dnsdist-21"},
    ],
}


def make_cfg(*, infra=None, services=None, extra=None):
    """Build a minimal valid config dict."""
    import copy
    cfg = {
        "environment":  "sandbox",
        "domain_name":  "test.example.com",
        "ssh":          BASE_SSH,
        "infrastructure": copy.deepcopy(infra if infra is not None else BASE_INFRA),
        "terraform":    BASE_TERRAFORM,
        "services":     copy.deepcopy(services if services is not None else {
            "minio": BASE_MINIO,
            "pki":   BASE_PKI,
            "dns":   BASE_DNS,
            "nexus": BASE_NEXUS,
        }),
    }
    if extra:
        cfg.update(extra)
    return cfg


def assert_exits(test_case, cfg, expected_fragment=None):
    """Assert that validate_schema or a gen_* call exits with code 1.

    Captures stderr and optionally checks for a string fragment in the error message.
    """
    old_stderr = sys.stderr
    sys.stderr = buf = io.StringIO()
    try:
        with test_case.assertRaises(SystemExit) as cm:
            gen.validate_schema(cfg)
    finally:
        sys.stderr = old_stderr
    test_case.assertEqual(cm.exception.code, 1, "Expected exit code 1")
    if expected_fragment:
        err = buf.getvalue()
        test_case.assertIn(
            expected_fragment, err,
            f"Expected {expected_fragment!r} in stderr.\nGot: {err!r}",
        )


def silence_stderr(fn):
    """Run fn with stderr suppressed (for expected-error gen_* calls)."""
    old_stderr = sys.stderr
    sys.stderr = io.StringIO()
    try:
        return fn()
    finally:
        sys.stderr = old_stderr


# ---------------------------------------------------------------------------
# Validation error tests
# ---------------------------------------------------------------------------

class TestValidationErrors(unittest.TestCase):

    def test_old_schema_singular_network(self):
        """Migration detector: infrastructure.network (singular) → hard error."""
        cfg = make_cfg()
        cfg["infrastructure"]["network"] = {"bridge": "lab", "cidr": "10.0.0.0/24", "gateway": "10.0.0.1"}
        assert_exits(self, cfg, "infrastructure.network' is no longer supported")

    def test_missing_networks_key(self):
        """No infrastructure.networks key → hard error."""
        cfg = make_cfg()
        del cfg["infrastructure"]["networks"]
        assert_exits(self, cfg, "infrastructure.networks")

    def test_empty_networks_dict(self):
        """infrastructure.networks: {} → hard error."""
        cfg = make_cfg()
        cfg["infrastructure"]["networks"] = {}
        assert_exits(self, cfg, "infrastructure.networks")

    def test_network_missing_bridge(self):
        """Network entry missing 'bridge' field → hard error."""
        cfg = make_cfg()
        del cfg["infrastructure"]["networks"]["lab"]["bridge"]
        assert_exits(self, cfg, "missing required field 'bridge'")

    def test_network_missing_cidr(self):
        """Network entry missing 'cidr' field → hard error."""
        cfg = make_cfg()
        del cfg["infrastructure"]["networks"]["lab"]["cidr"]
        assert_exits(self, cfg, "missing required field 'cidr'")

    def test_network_missing_gateway(self):
        """Network entry missing 'gateway' field → hard error."""
        cfg = make_cfg()
        del cfg["infrastructure"]["networks"]["lab"]["gateway"]
        assert_exits(self, cfg, "missing required field 'gateway'")

    def test_network_cidr_bare_ip(self):
        """Bare IP (no prefix) in network cidr → hard error."""
        cfg = make_cfg()
        cfg["infrastructure"]["networks"]["lab"]["cidr"] = "10.10.40.0"
        assert_exits(self, cfg, "CIDR notation")

    def test_default_network_nonexistent(self):
        """default_network references a network not in infrastructure.networks → hard error."""
        cfg = make_cfg()
        cfg["infrastructure"]["default_network"] = "nonexistent"
        assert_exits(self, cfg, "default_network 'nonexistent' is not defined")

    def test_service_network_nonexistent(self):
        """Service references a network not defined in infrastructure.networks → hard error."""
        cfg = make_cfg()
        cfg["infrastructure"]["default_network"] = None
        cfg["services"]["minio"]["network"] = "nonexistent"
        # validate_schema passes (no stale gateway); resolve_network in gen_* would catch it
        # but we test via resolve_network directly
        old_stderr = sys.stderr
        sys.stderr = io.StringIO()
        try:
            with self.assertRaises(SystemExit) as cm:
                gen.resolve_network(
                    {"network": "nonexistent"},
                    cfg["infrastructure"]["networks"],
                    None,
                    "minio",
                )
        finally:
            sys.stderr = old_stderr
        self.assertEqual(cm.exception.code, 1)

    def test_service_missing_network_no_default(self):
        """Service has no 'network:' field and no default_network → hard error."""
        cfg = make_cfg()
        cfg["infrastructure"]["default_network"] = None
        del cfg["services"]["minio"]["network"]
        old_stderr = sys.stderr
        sys.stderr = io.StringIO()
        try:
            with self.assertRaises(SystemExit) as cm:
                gen.resolve_network(
                    cfg["services"]["minio"],
                    cfg["infrastructure"]["networks"],
                    None,
                    "minio",
                )
        finally:
            sys.stderr = old_stderr
        self.assertEqual(cm.exception.code, 1)

    def test_stale_gateway_flat_service(self):
        """Flat service with 'gateway:' key → hard error."""
        cfg = make_cfg()
        cfg["services"]["minio"]["gateway"] = "10.10.40.1"
        assert_exits(self, cfg, "Remove 'gateway:' from service 'minio'")

    def test_stale_gateway_nested_service(self):
        """Nested service sub-dict with 'gateway:' key → hard error."""
        cfg = make_cfg()
        cfg["services"]["pki"]["root_ca"]["gateway"] = "10.10.40.1"
        assert_exits(self, cfg, "Remove 'gateway:' from service 'pki.root_ca'")

    def test_stale_gateway_nested_dns(self):
        """DNS nested sub-dict with 'gateway:' key → hard error."""
        cfg = make_cfg()
        cfg["services"]["dns"]["auth"]["gateway"] = "10.10.40.1"
        assert_exits(self, cfg, "Remove 'gateway:' from service 'dns.auth'")


# ---------------------------------------------------------------------------
# tfvars output content tests
# ---------------------------------------------------------------------------

class TestTfvarsOutput(unittest.TestCase):

    def _tfvars(self, cfg):
        return gen.gen_tfvars(cfg, "sandbox")

    def _entry(self, out, svc_key):
        """Extract one services-map entry block, whitespace-normalized for assertions."""
        import re
        lines = out.splitlines()
        start = next(i for i, l in enumerate(lines) if l.startswith(f"  {svc_key} = {{"))
        end = next(i for i in range(start, len(lines)) if lines[i] == "  }")
        return "\n".join(re.sub(r"\s+", " ", l).strip() for l in lines[start:end + 1])

    def test_enabled_services_present_in_map(self):
        """Every enabled service appears as a services-map entry."""
        out = self._tfvars(make_cfg())
        for svc_key in ("root_ca", "issuing_ca", "dns_auth", "dns_dist", "nexus"):
            self.assertIn(f"  {svc_key} = {{", out, f"Missing map entry: {svc_key}")

    def test_disabled_service_absent_from_map(self):
        """A service without enabled: true is absent from the services map."""
        import copy
        services = {
            "minio": BASE_MINIO,
            "pki":   copy.deepcopy(BASE_PKI),
            "dns":   BASE_DNS,
            "nexus": BASE_NEXUS,
        }
        services["pki"]["enabled"] = False
        out = self._tfvars(make_cfg(services=services))
        self.assertNotIn("root_ca = {", out)
        self.assertNotIn("issuing_ca = {", out)
        self.assertIn("dns_auth = {", out)

    def test_global_bridge_not_emitted(self):
        """No top-level 'bridge =' var — bridge lives inside each map entry."""
        out = self._tfvars(make_cfg())
        for line in out.splitlines():
            self.assertFalse(
                line.startswith("bridge ") or line.startswith("bridge="),
                f"Found a top-level 'bridge =' line: {line!r}",
            )

    def test_vlan_id_not_emitted(self):
        """vlan_id must NOT appear in tfvars (hardcoded null in main.tf)."""
        out = self._tfvars(make_cfg())
        self.assertNotIn("vlan_id", out)

    def test_network_cidr_not_emitted(self):
        """network_cidr must NOT appear in tfvars."""
        out = self._tfvars(make_cfg())
        self.assertNotIn("network_cidr", out)

    def test_gateway_sourced_from_network(self):
        """Gateway values must come from network definition, not service dict."""
        cfg = make_cfg()
        cfg["infrastructure"]["networks"]["lab"]["gateway"] = "10.10.40.254"
        out = self._tfvars(cfg)
        for svc_key in ("root_ca", "issuing_ca", "dns_auth", "dns_dist"):
            entry = self._entry(out, svc_key)
            self.assertIn('ipv4_gateway = "10.10.40.254"', entry,
                          f"{svc_key} gateway not sourced from network")

    def test_multi_network_bridge_per_service(self):
        """Services on different networks emit the correct bridge per service."""
        import copy
        cfg = make_cfg()
        cfg["infrastructure"]["networks"]["lan"] = {
            "bridge":  "lan",
            "cidr":    "10.10.10.0/24",
            "gateway": "10.10.10.1",
            "vlan_id": None,
        }
        cfg["infrastructure"]["default_network"] = None
        cfg["services"]["pki"]["root_ca"]["network"]    = "lab"
        cfg["services"]["pki"]["issuing_ca"]["network"] = "lab"
        cfg["services"]["dns"]["auth"]["network"]       = "lab"
        cfg["services"]["dns"]["dist"]["network"]       = "lan"
        cfg["services"]["minio"]["network"]             = "lab"

        out = self._tfvars(cfg)
        dist = self._entry(out, "dns_dist")
        self.assertIn('bridge = "lan"', dist)
        self.assertIn('ipv4_gateway = "10.10.10.1"', dist)
        auth = self._entry(out, "dns_auth")
        self.assertIn('bridge = "lab"', auth)
        self.assertIn('ipv4_gateway = "10.10.40.1"', auth)
        self.assertIn('bridge = "lab"', self._entry(out, "root_ca"))
        self.assertIn('bridge = "lab"', self._entry(out, "issuing_ca"))

    def test_sparse_no_dns_rejected(self):
        """Config without services.dns is invalid — schema requires pki+dns+nexus."""
        cfg = make_cfg(services={"minio": BASE_MINIO, "pki": BASE_PKI, "nexus": BASE_NEXUS})
        with self.assertRaises(SystemExit) as cm:
            silence_stderr(lambda: gen.validate_schema(cfg))
        self.assertIn("services.dns", str(cm.exception.code))

    def test_sparse_no_pki_rejected(self):
        """Config without services.pki is invalid — schema requires pki+dns+nexus."""
        cfg = make_cfg(services={"minio": BASE_MINIO, "dns": BASE_DNS, "nexus": BASE_NEXUS})
        with self.assertRaises(SystemExit) as cm:
            silence_stderr(lambda: gen.validate_schema(cfg))
        self.assertIn("services.pki", str(cm.exception.code))


# ---------------------------------------------------------------------------
# Squid allowlist tests
# ---------------------------------------------------------------------------

class TestAllowedCidrs(unittest.TestCase):

    def _cidrs(self, cfg):
        return gen.gen_allowed_cidrs(cfg, "sandbox")

    def test_single_network_one_cidr(self):
        """Single network → exactly one network CIDR in allowlist."""
        out = self._cidrs(make_cfg())
        self.assertIn("10.10.40.0/24", out)

    def test_proxmox_always_present(self):
        """Proxmox /32 always appears regardless of service network."""
        out = self._cidrs(make_cfg())
        self.assertIn("10.0.0.1/32", out)

    def test_two_services_same_network_one_cidr(self):
        """Two services on the same network → CIDR appears only once."""
        out = self._cidrs(make_cfg())
        count = out.count("10.10.40.0/24")
        self.assertEqual(count, 1, f"Expected 1 occurrence, got {count}")

    def test_multi_network_all_cidrs_emitted(self):
        """Services on distinct networks → all CIDRs emitted."""
        import copy
        cfg = make_cfg()
        cfg["infrastructure"]["networks"]["lan"] = {
            "bridge":  "lan",
            "cidr":    "10.10.10.0/24",
            "gateway": "10.10.10.1",
            "vlan_id": None,
        }
        cfg["infrastructure"]["default_network"] = None
        cfg["services"]["pki"]["root_ca"]["network"]    = "lab"
        cfg["services"]["pki"]["issuing_ca"]["network"] = "lab"
        cfg["services"]["dns"]["auth"]["network"]       = "lab"
        cfg["services"]["dns"]["dist"]["network"]       = "lan"
        cfg["services"]["minio"]["network"]             = "lab"

        out = self._cidrs(cfg)
        self.assertIn("10.10.40.0/24", out)
        self.assertIn("10.10.10.0/24", out)

    def test_unused_network_not_emitted(self):
        """Network defined but no service uses it → CIDR not emitted."""
        cfg = make_cfg()
        cfg["infrastructure"]["networks"]["unused"] = {
            "bridge":  "unused",
            "cidr":    "172.16.0.0/24",
            "gateway": "172.16.0.1",
            "vlan_id": None,
        }
        out = self._cidrs(cfg)
        self.assertNotIn("172.16.0.0/24", out)

    def test_no_minio_slash32(self):
        """MinIO /32 must NOT appear — covered by its network CIDR."""
        out = self._cidrs(make_cfg())
        # MinIO is at 10.10.40.5; /32 of that must not be present
        self.assertNotIn("10.10.40.5/32", out)

    def test_three_distinct_networks(self):
        """Three distinct networks with services → all three CIDRs emitted."""
        import copy
        cfg = make_cfg()
        cfg["infrastructure"]["networks"]["mgmt"] = {
            "bridge":  "mgmt",
            "cidr":    "10.10.30.0/24",
            "gateway": "10.10.30.1",
            "vlan_id": None,
        }
        cfg["infrastructure"]["networks"]["lan"] = {
            "bridge":  "lan",
            "cidr":    "10.10.10.0/24",
            "gateway": "10.10.10.1",
            "vlan_id": None,
        }
        cfg["infrastructure"]["default_network"] = None
        cfg["services"]["minio"]["network"]             = "lab"
        cfg["services"]["pki"]["root_ca"]["network"]    = "mgmt"
        cfg["services"]["pki"]["issuing_ca"]["network"] = "mgmt"
        cfg["services"]["dns"]["auth"]["network"]       = "mgmt"
        cfg["services"]["dns"]["dist"]["network"]       = "lan"

        out = self._cidrs(cfg)
        self.assertIn("10.10.40.0/24", out)   # lab (minio)
        self.assertIn("10.10.30.0/24", out)   # mgmt (pki, dns-auth)
        self.assertIn("10.10.10.0/24", out)   # lan (dns-dist)

    def test_service_without_ip_not_counted(self):
        """Services without 'ip' field don't contribute a network CIDR."""
        cfg = make_cfg(services={"minio": BASE_MINIO})
        # minio is on lab; no pki/dns
        out = self._cidrs(cfg)
        self.assertIn("10.10.40.0/24", out)
        # Only the lab CIDR and proxmox /32 — no PKI or DNS networks
        lines = [l for l in out.splitlines() if l and not l.startswith("#")]
        self.assertEqual(len(lines), 2)  # lab CIDR + proxmox /32


# ---------------------------------------------------------------------------
# Inventory output tests
# ---------------------------------------------------------------------------

class TestInventoryOutput(unittest.TestCase):

    def _inv(self, cfg):
        return gen.gen_inventory(cfg, "sandbox")

    def test_dns_dist_acl_uses_dist_network_cidr(self):
        """pdns_dnsdist_acl_cidrs base CIDR comes from dns.dist's network, not a global cidr."""
        import copy
        cfg = make_cfg()
        cfg["infrastructure"]["networks"]["lan"] = {
            "bridge":  "lan",
            "cidr":    "10.10.10.0/24",
            "gateway": "10.10.10.1",
            "vlan_id": None,
        }
        cfg["infrastructure"]["default_network"] = None
        cfg["services"]["minio"]["network"]             = "lab"
        cfg["services"]["pki"]["root_ca"]["network"]    = "lab"
        cfg["services"]["pki"]["issuing_ca"]["network"] = "lab"
        cfg["services"]["dns"]["auth"]["network"]       = "lab"
        cfg["services"]["dns"]["dist"]["network"]       = "lan"
        cfg["services"]["dns"]["dist"]["client_cidrs"]  = []

        out = self._inv(cfg)
        # Base ACL CIDR should be the lan network (where dist lives), not lab
        self.assertIn("10.10.10.0/24", out)
        # lab CIDR should NOT be in the dist ACL (no client_cidrs from lab)
        # (It may appear elsewhere in inventory for other hosts, so check only ACL context)
        lines = out.splitlines()
        acl_block = False
        acl_lines = []
        for line in lines:
            if "pdns_dnsdist_acl_cidrs" in line:
                acl_block = True
            if acl_block:
                acl_lines.append(line)
                if acl_lines and not line.startswith("          ") and len(acl_lines) > 1:
                    break
        self.assertTrue(any("10.10.10.0/24" in l for l in acl_lines))
        self.assertFalse(any("10.10.40.0/24" in l for l in acl_lines))

    def test_dns_dist_acl_deduplication(self):
        """client_cidrs overlapping with base network CIDR → appears only once."""
        import copy
        cfg = make_cfg()
        # dist is on lab; client_cidrs also includes lab CIDR
        cfg["services"]["dns"]["dist"]["client_cidrs"] = ["10.10.40.0/24"]

        out = self._inv(cfg)
        # Count occurrences of lab CIDR in the ACL block
        count = out.count("10.10.40.0/24")
        self.assertEqual(count, 1, f"Expected CIDR deduplicated to 1 occurrence, got {count}")

    def test_dns_dist_acl_client_cidrs_third_network(self):
        """client_cidrs from a network not used by any service still appears in ACL."""
        import copy
        cfg = make_cfg()
        cfg["services"]["dns"]["dist"]["client_cidrs"] = ["192.168.100.0/24"]

        out = self._inv(cfg)
        # The base CIDR (lab) + the client cidr should both appear
        self.assertIn("10.10.40.0/24", out)
        self.assertIn("192.168.100.0/24", out)

    def test_dns_dist_no_client_cidrs(self):
        """dns.dist with no client_cidrs → only base network CIDR in ACL."""
        import copy
        cfg = make_cfg()
        cfg["services"]["dns"]["dist"]["client_cidrs"] = []

        out = self._inv(cfg)
        lines = out.splitlines()
        acl_lines = []
        collecting = False
        for line in lines:
            if "pdns_dnsdist_acl_cidrs" in line:
                collecting = True
            if collecting:
                acl_lines.append(line)
                if collecting and line.strip().startswith("-"):
                    continue
                elif collecting and len(acl_lines) > 1 and not line.strip().startswith("-"):
                    break
        cidr_entries = [l for l in acl_lines if l.strip().startswith("-")]
        self.assertEqual(len(cidr_entries), 1, f"Expected 1 ACL entry, got {len(cidr_entries)}: {cidr_entries}")

    def test_sparse_no_dns_no_dns_groups(self):
        """Config without dns section → no dns_auth or dns_dist groups in inventory."""
        import copy
        cfg = make_cfg(services={"minio": BASE_MINIO, "pki": BASE_PKI})
        out = self._inv(cfg)
        self.assertNotIn("dns_auth", out)
        self.assertNotIn("dns_dist", out)

    def test_sparse_no_pki_no_pki_groups(self):
        """Config without pki section → no pki_ groups in inventory."""
        import copy
        dns = copy.deepcopy(BASE_DNS)
        cfg = make_cfg(services={"minio": BASE_MINIO, "dns": dns})
        out = self._inv(cfg)
        self.assertNotIn("pki_root_ca", out)
        self.assertNotIn("pki_issuing_ca", out)


# ---------------------------------------------------------------------------
# resolve_network helper tests
# ---------------------------------------------------------------------------

class TestResolveNetwork(unittest.TestCase):

    NETWORKS = {
        "lab": {"bridge": "lab", "cidr": "10.10.40.0/24", "gateway": "10.10.40.1"},
        "lan": {"bridge": "lan", "cidr": "10.10.10.0/24", "gateway": "10.10.10.1"},
    }

    def test_explicit_network_field(self):
        """Explicit 'network:' field → returns correct network dict."""
        result = gen.resolve_network({"network": "lan"}, self.NETWORKS, "lab", "test.svc")
        self.assertEqual(result["bridge"], "lan")

    def test_default_network_fallback(self):
        """No 'network:' field + default_network → uses default."""
        result = gen.resolve_network({}, self.NETWORKS, "lab", "test.svc")
        self.assertEqual(result["bridge"], "lab")

    def test_explicit_overrides_default(self):
        """Explicit 'network:' overrides default_network."""
        result = gen.resolve_network({"network": "lan"}, self.NETWORKS, "lab", "test.svc")
        self.assertEqual(result["bridge"], "lan")

    def test_unknown_network_exits(self):
        """Unknown 'network:' value → exits 1."""
        old_stderr = sys.stderr
        sys.stderr = io.StringIO()
        try:
            with self.assertRaises(SystemExit) as cm:
                gen.resolve_network({"network": "nonexistent"}, self.NETWORKS, "lab", "test.svc")
        finally:
            sys.stderr = old_stderr
        self.assertEqual(cm.exception.code, 1)

    def test_no_network_no_default_exits(self):
        """No 'network:' field + no default_network → exits 1."""
        old_stderr = sys.stderr
        sys.stderr = io.StringIO()
        try:
            with self.assertRaises(SystemExit) as cm:
                gen.resolve_network({}, self.NETWORKS, None, "test.svc")
        finally:
            sys.stderr = old_stderr
        self.assertEqual(cm.exception.code, 1)


# ---------------------------------------------------------------------------
# DNS record derivation tests
# ---------------------------------------------------------------------------

class TestDeriveDnsRecords(unittest.TestCase):

    def test_dns_aliases_emit_extra_records(self):
        """dns_aliases on a nested service adds records at the same IP."""
        import copy
        pki = copy.deepcopy(BASE_PKI)
        pki["issuing_ca"]["dns_aliases"] = ["ca"]
        records = gen._derive_dns_records({"pki": pki})
        by_name = {r["name"]: r for r in records}
        self.assertIn("issuing-ca", by_name)  # primary label kept
        self.assertIn("ca", by_name)          # alias added
        self.assertEqual(by_name["ca"]["ip"], by_name["issuing-ca"]["ip"])

    def test_dns_false_suppresses_aliases_too(self):
        """dns: false removes the host AND its aliases from records."""
        svc = {"web": {"ip": "10.0.0.9", "dns": False, "dns_aliases": ["www"], "node": "pve"}}
        records = gen._derive_dns_records(svc)
        self.assertEqual(records, [])


# ---------------------------------------------------------------------------
# .envrc smart-merge tests (atomic_write)
# ---------------------------------------------------------------------------

class TestEnvrcSmartMerge(unittest.TestCase):

    def _merge(self, existing, generated):
        """Run atomic_write against a real temp .envrc and return the merged text."""
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, ".envrc")
            with open(path, "w") as f:
                f.write(existing)
            return gen.atomic_write(path, generated)

    def test_filled_secret_preserved(self):
        """A filled-in secret survives regeneration over its CHANGE_ME slot."""
        existing  = 'export MINIO_ROOT_PASSWORD="realvalue123"\n'
        generated = f'export MINIO_ROOT_PASSWORD="{gen.CHANGE_ME}"\n'
        merged = self._merge(existing, generated)
        self.assertIn('export MINIO_ROOT_PASSWORD="realvalue123"', merged)
        self.assertNotIn(gen.CHANGE_ME, merged)

    def test_operator_added_key_carried_over(self):
        """An export the generator never emitted is carried, not deleted."""
        existing = (
            'export MINIO_ROOT_PASSWORD="realvalue123"\n'
            'export OPERATOR_CUSTOM_FLAG="keep-me"\n'
        )
        generated = f'export MINIO_ROOT_PASSWORD="{gen.CHANGE_ME}"\n'
        merged = self._merge(existing, generated)
        self.assertIn('export OPERATOR_CUSTOM_FLAG="keep-me"', merged)
        self.assertIn(".envrc.local", merged)  # carried block points at the seam

    def test_carry_over_idempotent(self):
        """Regenerating twice does not duplicate carried lines or headers."""
        existing  = 'export OPERATOR_CUSTOM_FLAG="keep-me"\n'
        generated = f'export MINIO_ROOT_PASSWORD="{gen.CHANGE_ME}"\n'
        once  = self._merge(existing, generated)
        twice = self._merge(once, generated)
        self.assertEqual(once.count('export OPERATOR_CUSTOM_FLAG="keep-me"'), 1)
        self.assertEqual(twice.count('export OPERATOR_CUSTOM_FLAG="keep-me"'), 1)
        self.assertEqual(
            twice.count("Preserved from the previous .envrc"), 1,
            "carry-over header must not accumulate across regenerations",
        )

    def test_emitted_commented_var_not_carried(self):
        """A var the template emits commented-out (opt-in) is not duplicated by carry-over."""
        existing  = 'export SSL_CERT_FILE=/workspace/.pki/root_ca.crt\n'
        generated = '# export SSL_CERT_FILE=/workspace/.pki/root_ca.crt\n'
        merged = self._merge(existing, generated)
        # uncommented-opt-in restore path handles it; carry-over must not add a second copy
        self.assertEqual(merged.count("export SSL_CERT_FILE"), 1)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    unittest.main(verbosity=2 if "-v" in sys.argv else 1)
