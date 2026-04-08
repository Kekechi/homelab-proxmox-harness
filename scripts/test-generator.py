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
    "proxmox": {"ip": "10.0.0.1", "port": 8006, "node": "pve", "insecure": True},
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
    "ip":           "10.10.40.5",
    "port":         9000,
    "ansible_user": "root",
    "hostname":     "minio",
    "fqdn":         "minio.example.com",
    "tls":          False,
}

BASE_PKI = {
    "root_ca": {
        "ip":                    "10.10.40.10/24",
        "vm_id":                 201,
        "ansible_user":          "debian",
        "hostname":              "root-ca",
        "cloud_init_template_id": 9000,
    },
    "issuing_ca": {
        "ip":                    "10.10.40.11/24",
        "ct_id":                 202,
        "ansible_user":          "root",
        "hostname":              "issuing-ca",
        "lxc_template_file_id": "local:vztmpl/debian-12.tar.xz",
    },
}

BASE_DNS = {
    "auth": {
        "ip":           "10.10.40.12/24",
        "ct_id":        203,
        "ansible_user": "root",
        "hostname":     "dns-auth",
    },
    "dist": {
        "ip":           "10.10.40.13/24",
        "ct_id":        204,
        "ansible_user": "root",
        "hostname":     "dns-dist",
        "client_cidrs": ["10.10.10.0/24"],
    },
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

    def test_per_service_bridge_vars_emitted(self):
        """All four per-service bridge vars must appear in tfvars."""
        out = self._tfvars(make_cfg())
        for var in ("root_ca_bridge", "issuing_ca_bridge", "dns_auth_bridge", "dns_dist_bridge"):
            self.assertIn(var, out, f"Missing: {var}")

    def test_global_bridge_not_emitted(self):
        """Global 'bridge =' line must NOT appear in tfvars (only per-service *_bridge vars)."""
        out = self._tfvars(make_cfg())
        for line in out.splitlines():
            stripped = line.lstrip()
            self.assertFalse(
                stripped.startswith("bridge ") or stripped.startswith("bridge="),
                f"Found a global 'bridge =' line: {line!r}",
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
        self.assertIn('root_ca_ipv4_gateway    = "10.10.40.254"', out)
        self.assertIn('issuing_ca_ipv4_gateway = "10.10.40.254"', out)
        self.assertIn('dns_auth_ipv4_gateway   = "10.10.40.254"', out)
        self.assertIn('dns_dist_ipv4_gateway   = "10.10.40.254"', out)

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
        self.assertIn('dns_dist_bridge         = "lan"',  out)
        self.assertIn('dns_dist_ipv4_gateway   = "10.10.10.1"', out)
        self.assertIn('dns_auth_bridge         = "lab"',  out)
        self.assertIn('dns_auth_ipv4_gateway   = "10.10.40.1"', out)
        self.assertIn('root_ca_bridge          = "lab"',  out)
        self.assertIn('issuing_ca_bridge       = "lab"',  out)

    def test_sparse_no_dns_section(self):
        """Config without services.dns → no DNS lines in tfvars."""
        cfg = make_cfg(services={"minio": BASE_MINIO, "pki": BASE_PKI})
        out = self._tfvars(cfg)
        self.assertNotIn("dns_auth", out)
        self.assertNotIn("dns_dist", out)

    def test_sparse_no_pki_section(self):
        """Config without services.pki → no PKI lines in tfvars."""
        import copy
        dns = copy.deepcopy(BASE_DNS)
        cfg = make_cfg(services={"minio": BASE_MINIO, "dns": dns})
        out = self._tfvars(cfg)
        self.assertNotIn("root_ca", out)
        self.assertNotIn("issuing_ca", out)


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
        dns = {k: dict(v) for k, v in BASE_DNS.items()}
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
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    unittest.main(verbosity=2 if "-v" in sys.argv else 1)
