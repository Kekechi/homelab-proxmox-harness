#!/usr/bin/env python3
"""
generate-configs.py — Generate environment config files from config/<env>.yml

Reads config/<env>.yml and generates:
  - terraform/<env>.tfvars
  - ansible/inventory/hosts.yml
  - .devcontainer/squid/allowed-cidrs.conf
  - .envrc (non-secret portion, with CHANGE_ME placeholders for secrets)
  - .env.mk (Makefile-includable variables)

Usage:
  python3 scripts/generate-configs.py [sandbox|production] [--force]

Options:
  --force   Overwrite .envrc even if it contains non-placeholder secrets
"""

import sys
import os
import re
import shutil
import textwrap

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is required. Install with: pip install pyyaml", file=sys.stderr)
    sys.exit(1)

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHANGE_ME = "CHANGE_ME"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def load_config(env: str) -> dict:
    path = os.path.join(REPO_ROOT, "config", f"{env}.yml")
    if not os.path.exists(path):
        example = f"config/{env}.yml.example"
        print(f"ERROR: config/{env}.yml not found.", file=sys.stderr)
        print(f"       Copy the example and fill in your values:", file=sys.stderr)
        print(f"       cp {example} config/{env}.yml", file=sys.stderr)
        sys.exit(1)
    with open(path) as f:
        return yaml.safe_load(f)


def validate_cidr(value: str, field: str):
    """Reject bare IPs without a prefix length."""
    if value and "/" not in str(value):
        print(f"ERROR: {field} must use CIDR notation (e.g., 192.168.1.0/24 or 192.168.1.5/32).", file=sys.stderr)
        sys.exit(1)


def validate_domain_name(value: str, field: str):
    """Reject domain names with characters that would produce invalid YAML."""
    import re
    if value and not re.match(r'^[a-zA-Z0-9.-]+$', value):
        print(f"ERROR: {field} contains invalid characters. Only alphanumerics, dots, and hyphens are allowed.", file=sys.stderr)
        print(f"       Got: {value!r}", file=sys.stderr)
        sys.exit(1)


def _strip_prefix(addr: str) -> str:
    """Strip CIDR prefix: '10.0.0.1/24' → '10.0.0.1'."""
    return addr.split("/")[0] if addr else addr


def resolve_network(svc_dict: dict, networks: dict, default_network: str, service_label: str) -> dict:
    """Resolve the network dict for a service.

    Looks up svc_dict.get("network") in networks; falls back to networks[default_network]
    if default_network is set. Hard errors if neither is available or the referenced
    network name is not a key in networks.
    """
    net_name = svc_dict.get("network")
    if net_name is not None:
        if net_name not in networks:
            print(
                f"ERROR: Service '{service_label}' references network '{net_name}' "
                f"which is not defined in infrastructure.networks.",
                file=sys.stderr,
            )
            sys.exit(1)
        return networks[net_name]
    if default_network:
        return networks[default_network]
    print(
        f"ERROR: Service '{service_label}' has no 'network:' field and no "
        f"'default_network' is set in infrastructure. "
        f"Add a 'network:' field to this service or set 'infrastructure.default_network'.",
        file=sys.stderr,
    )
    sys.exit(1)


def _derive_dns_records(svcs: dict) -> list[dict]:
    """Derive DNS A record entries from services config.

    Returns a list of dicts with keys: name, ip, ttl.
    - Flat services (top-level 'ip'): label = service key, underscores → hyphens.
    - Nested services (sub-dicts with 'ip'): label = sub-key, underscores → hyphens.
    - dns_name: override the label; dns_ttl: override TTL (default 3600); dns: false skips the entry.
    """
    records = []
    for svc_name, svc in svcs.items():
        if not isinstance(svc, dict):
            continue
        if "ip" in svc:
            # Flat service (e.g. minio)
            if svc.get("dns") is False:
                continue
            label = svc.get("dns_name") or svc_name.replace("_", "-")
            ip = _strip_prefix(svc["ip"])
            ttl = int(svc.get("dns_ttl", 3600))
            records.append({"name": label, "ip": ip, "ttl": ttl})
        else:
            # Nested service (e.g. pki.root_ca, dns.auth)
            for subkey, sub in svc.items():
                if not isinstance(sub, dict) or "ip" not in sub:
                    continue
                if sub.get("dns") is False:
                    continue
                label = sub.get("dns_name") or subkey.replace("_", "-")
                ip = _strip_prefix(sub["ip"])
                ttl = int(sub.get("dns_ttl", 3600))
                records.append({"name": label, "ip": ip, "ttl": ttl})
    return records


def is_inside_container() -> bool:
    """Detect if we're running inside the dev container."""
    if os.path.exists("/.dockerenv"):
        return True
    proxy = os.environ.get("http_proxy", "") or os.environ.get("HTTP_PROXY", "")
    return "squid-proxy" in proxy


# Secret variable names written into .envrc — used to detect filled-in values.
_ENVRC_SECRET_VARS = [
    "PROXMOX_VE_API_TOKEN",
    "MINIO_ROOT_USER",
    "MINIO_ROOT_PASSWORD",
    "MINIO_ACCESS_KEY",
    "MINIO_SECRET_KEY",
    "STEP_CA_ROOT_PASSWORD",
    "STEP_CA_ISSUING_PASSWORD",
    "STEP_CA_LXC_ROOT_PASSWORD",
    "STEP_CA_PROVISIONER_PASSWORD",
    "PDNS_AUTH_API_KEY",
    "PDNS_RECURSOR_API_KEY",
    "PDNS_DNSDIST_API_KEY",
    "NEXUS_ADMIN_PASSWORD",
    "NEXUS_READER_PASSWORD",
    "OTELCOL_MINIO_ACCESS_KEY",
    "OTELCOL_MINIO_SECRET_KEY",
]


def atomic_write(path: str, content: str, force: bool = False):
    """Write content atomically. For .envrc, preserve filled-in secrets via smart merge."""
    if os.path.basename(path) == ".envrc" and os.path.exists(path) and not force:
        with open(path) as f:
            existing = f.read()

        # Extract secret values the user has already filled in (i.e. not CHANGE_ME or empty).
        preserved = {}
        for line in existing.splitlines():
            for var in _ENVRC_SECRET_VARS:
                m = re.match(rf'^export {re.escape(var)}="([^"]*)"', line)
                if m and m.group(1) not in ("", CHANGE_ME):
                    preserved[var] = m.group(1)

        # Track which non-secret vars the user has explicitly uncommented (e.g. SSL_CERT_FILE).
        uncommented = set()
        for line in existing.splitlines():
            m = re.match(r'^export (\w+)=', line)
            if m and m.group(1) not in _ENVRC_SECRET_VARS:
                uncommented.add(m.group(1))

        # Substitute preserved secrets and restore uncommented opt-in lines.
        merged = []
        for line in content.splitlines():
            replaced = False
            for var, value in preserved.items():
                m = re.match(
                    rf'^(export {re.escape(var)}="){re.escape(CHANGE_ME)}"(.*)', line
                )
                if m:
                    escaped = value.replace('"', '\\"')
                    merged.append(f'{m.group(1)}{escaped}"{m.group(2)}')
                    replaced = True
                    break
            if not replaced:
                # Uncomment lines the user had previously activated.
                m = re.match(r'^# (export (\w+)=.*)', line)
                if m and m.group(2) in uncommented:
                    merged.append(m.group(1))
                    replaced = True
            if not replaced:
                merged.append(line)
        content = "\n".join(merged) + "\n"

    tmp = path + ".new"
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(tmp, "w") as f:
        f.write(content)
    try:
        os.rename(tmp, path)
    except Exception:
        os.unlink(tmp)
        raise
    return content


def write_file(path: str, content: str, label: str):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(content)
    rel = os.path.relpath(path, REPO_ROOT)
    print(f"  wrote  {rel}")


# ---------------------------------------------------------------------------
# Schema validation
# ---------------------------------------------------------------------------

def validate_schema(cfg: dict):
    """Validate config schema before generating any files. Exits on error."""
    infra = cfg.get("infrastructure", {})

    # Migration detector: singular 'network' key is no longer supported
    if "network" in infra:
        print(
            "ERROR: 'infrastructure.network' is no longer supported. "
            "Migrate to 'infrastructure.networks' (plural map). "
            "See config/sandbox.yml.example for the new schema.",
            file=sys.stderr,
        )
        sys.exit(1)

    # infrastructure.networks must exist and be a non-empty dict
    networks = infra.get("networks")
    if not networks or not isinstance(networks, dict):
        print(
            "ERROR: 'infrastructure.networks' must be a non-empty map of named networks.",
            file=sys.stderr,
        )
        sys.exit(1)

    # Each network entry must have bridge, cidr, gateway
    for name, net in networks.items():
        if not isinstance(net, dict):
            print(
                f"ERROR: infrastructure.networks.{name} must be a dict with bridge, cidr, gateway.",
                file=sys.stderr,
            )
            sys.exit(1)
        for required_field in ("bridge", "cidr", "gateway"):
            if required_field not in net:
                print(
                    f"ERROR: infrastructure.networks.{name} is missing required field '{required_field}'.",
                    file=sys.stderr,
                )
                sys.exit(1)
        validate_cidr(net["cidr"], f"infrastructure.networks.{name}.cidr")

    # Migration detector: old per-proxmox node field is no longer supported
    if cfg.get("infrastructure", {}).get("proxmox", {}).get("node"):
        sys.exit(
            "Config error: remove 'infrastructure.proxmox.node' — per-service node "
            "placement is now via 'node:' on each service. "
            "See docs/cluster-setup.md for migration steps."
        )

    # infrastructure.nodes must exist and be a non-empty dict
    nodes = cfg.get("infrastructure", {}).get("nodes")
    if not nodes or not isinstance(nodes, dict):
        sys.exit("Config error: 'infrastructure.nodes' must be a non-empty map.")
    for node_name, node_cfg in nodes.items():
        if not node_cfg.get("ip"):
            sys.exit(f"Config error: 'infrastructure.nodes.{node_name}' is missing required 'ip:' field.")

    # Required top-level service keys + sub-keys
    svcs = cfg.get("services", {})
    for required_key in ("pki", "dns", "nexus"):
        if required_key not in svcs:
            sys.exit(
                f"Config error: 'services.{required_key}' is required — "
                "all three Terraform-managed service groups (pki, dns, nexus) must be present."
            )
    for sub_path in ("pki.root_ca", "pki.issuing_ca", "dns.auth", "dns.dist"):
        keys = sub_path.split(".")
        obj = svcs
        for k in keys:
            obj = obj.get(k) if isinstance(obj, dict) else None
        if not obj:
            sys.exit(f"Config error: 'services.{sub_path}' is required and must be a non-empty map.")

    # Service node: walk — every leaf service must have a valid node: field
    node_keys = set(nodes.keys())

    def _check_service_node(service_dict, label):
        if not isinstance(service_dict, dict):
            return
        if "ip" in service_dict:
            # leaf service — require node:
            if "node" not in service_dict:
                sys.exit(f"Config error: service '{label}' is missing required 'node:' field.")
            if service_dict["node"] not in node_keys:
                sys.exit(
                    f"Config error: service '{label}' references node '{service_dict['node']}' "
                    f"which is not in 'infrastructure.nodes'. Valid nodes: {sorted(node_keys)}"
                )
        else:
            # nested — recurse
            for sub_key, sub_val in service_dict.items():
                if isinstance(sub_val, dict):
                    _check_service_node(sub_val, f"{label}.{sub_key}")

    for svc_name, svc_val in cfg.get("services", {}).items():
        _check_service_node(svc_val, svc_name)

    # default_network (if set) must reference a key in infrastructure.networks
    default_network = infra.get("default_network")
    if default_network is not None and default_network not in networks:
        print(
            f"ERROR: infrastructure.default_network '{default_network}' is not defined in "
            f"infrastructure.networks. Available networks: {list(networks.keys())}",
            file=sys.stderr,
        )
        sys.exit(1)

    # Stale gateway detector: scan all services for 'gateway' keys
    svcs = cfg.get("services", {}) or {}
    for svc_name, svc in svcs.items():
        if not isinstance(svc, dict):
            continue
        if "gateway" in svc:
            print(
                f"ERROR: Remove 'gateway:' from service '{svc_name}'. "
                f"Gateway is now defined in infrastructure.networks.<name>.gateway",
                file=sys.stderr,
            )
            sys.exit(1)
        # Check nested sub-dicts
        for subkey, sub in svc.items():
            if isinstance(sub, dict) and "gateway" in sub:
                print(
                    f"ERROR: Remove 'gateway:' from service '{svc_name}.{subkey}'. "
                    f"Gateway is now defined in infrastructure.networks.<name>.gateway",
                    file=sys.stderr,
                )
                sys.exit(1)


# ---------------------------------------------------------------------------
# Generators
# ---------------------------------------------------------------------------

def _hcl_str(val: str) -> str:
    """Return HCL string literal, or null if value is empty."""
    return f'"{val}"' if val else "null"


_NEXUS_REQUIRED_APT_REPOS = {
    "apt-proxy-trixie",
    "apt-proxy-trixie-security",
    "apt-proxy-trixie-updates",
    "apt-proxy-smallstep",
    "apt-proxy-powerdns-auth-50",
    "apt-proxy-powerdns-rec-54",
    "apt-proxy-dnsdist-21",
}


def validate_nexus_apt_proxy_repos(repos: list, field: str) -> None:
    """Assert all IaC-required APT proxy repo names are present and field values are safe."""
    _UNSAFE = {'"', "\n", "\r", "}", ","}
    for i, repo in enumerate(repos):
        if not isinstance(repo, dict):
            sys.exit(
                f"Config error: '{field}[{i}]' must be a mapping (got "
                f"{type(repo).__name__!r}). Each entry needs name, remote_url, "
                "and distribution keys."
            )
        for key in ("name", "remote_url", "distribution"):
            val = repo.get(key, "")
            if any(c in val for c in _UNSAFE):
                sys.exit(
                    f"Config error: '{field}[{i}].{key}' contains a character not allowed "
                    f"in generated YAML flow-mapping (\", }}, ,, or newline). Remove it and re-run."
                )
        if "flat" in repo and not isinstance(repo["flat"], bool):
            sys.exit(
                f"Config error: '{field}[{i}].flat' must be a boolean (true or false), "
                f"got {type(repo['flat']).__name__!r}."
            )
    present = {r["name"] for r in repos if isinstance(r, dict) and "name" in r}
    missing = _NEXUS_REQUIRED_APT_REPOS - present
    if missing:
        sys.exit(
            f"Config error: '{field}' is missing IaC-required repos: "
            f"{', '.join(sorted(missing))}. "
            "These repos are referenced by Ansible roles and must be present."
        )


def gen_tfvars(cfg: dict, env: str) -> str:
    infra = cfg.get("infrastructure", {})
    p = infra.get("proxmox", {})
    networks = infra["networks"]
    default_network = infra.get("default_network")
    s = infra.get("storage", {})
    t = cfg.get("terraform", {})
    ssh = cfg.get("ssh", {})
    svcs = cfg.get("services", {})
    pki = svcs.get("pki", {})

    pool_id = t.get("pool_id", "")
    ssh_key = ssh.get("public_key", "")
    domain_name = cfg.get("domain_name", "")

    # Widest key in this block: cloudinit_datastore_id (22 chars) — pad all to column 23
    lines = [
        f"# Generated by scripts/generate-configs.py from config/{env}.yml",
        f"# DO NOT EDIT — run `make configure` to regenerate.",
        f"",
        f'pool_id                = "{pool_id}"',
        f'datastore_id           = "{s.get("datastore_id", "local-lvm")}"',
        f'cloudinit_datastore_id = "{s.get("cloudinit_datastore_id", "local")}"',
        f'vm_id_range_start      = {t.get("vm_id_range_start", 200)}',
        f'clone_template_id      = {t.get("clone_template_id", 0)}',
        f'ssh_public_key         = "{ssh_key}"',
        f'domain_name            = {_hcl_str(domain_name)}',
    ]

    # lxc_template_file_id — global, read from infrastructure.storage
    lxc_tmpl = s.get("lxc_template_file_id", "")
    if lxc_tmpl:
        lines += [
            f"",
            f'lxc_template_file_id = {_hcl_str(lxc_tmpl)}',
        ]

    # Per-service node placement
    # minio node intentionally excluded — Ansible-only service, no Terraform consumer
    lines += [
        f"",
        f'root_ca_node    = "{svcs["pki"]["root_ca"]["node"]}"',
        f'issuing_ca_node = "{svcs["pki"]["issuing_ca"]["node"]}"',
        f'dns_auth_node   = "{svcs["dns"]["auth"]["node"]}"',
        f'dns_dist_node   = "{svcs["dns"]["dist"]["node"]}"',
        f'nexus_node      = "{svcs["nexus"]["node"]}"',
    ]

    # Deployment gating — derived from services.<svc>.enabled (default false)
    enable_pki        = bool(svcs.get("pki", {}).get("enabled", False))
    enable_dns        = bool(svcs.get("dns", {}).get("enabled", False))
    enable_nexus      = bool(svcs.get("nexus", {}).get("enabled", False))
    enable_log_server = bool(svcs.get("log_server", {}).get("enabled", False))
    dns_server   = infra.get("dns_server", "").strip()
    dns_servers_hcl = f'["{dns_server}"]' if dns_server else "[]"
    lines += [
        f"",
        f"# Deployment gating — set services.<svc>.enabled: true in config to unlock each phase",
        f'enable_pki        = {str(enable_pki).lower()}',
        f'enable_dns        = {str(enable_dns).lower()}',
        f'enable_nexus      = {str(enable_nexus).lower()}',
        f'enable_log_server = {str(enable_log_server).lower()}',
        f"",
        f"# DNS resolver injected into all LXC/VM initialization blocks",
        f'dns_servers = {dns_servers_hcl}',
    ]

    # PKI section — only emitted when services.pki is present in config
    if pki:
        root_ca  = pki.get("root_ca", {})
        iss_ca   = pki.get("issuing_ca", {})

        root_addr = root_ca.get("ip", "")
        iss_addr  = iss_ca.get("ip", "")

        if iss_ca.get("lxc_template_file_id"):
            print("ERROR: lxc_template_file_id found in services.pki.issuing_ca. "
                  "Move it to infrastructure.storage.lxc_template_file_id instead.", file=sys.stderr)
            sys.exit(1)

        validate_cidr(root_addr, "services.pki.root_ca.ip")
        validate_cidr(iss_addr, "services.pki.issuing_ca.ip")

        root_net = resolve_network(root_ca, networks, default_network, "pki.root_ca")
        iss_net  = resolve_network(iss_ca, networks, default_network, "pki.issuing_ca")

        lines += [
            f"",
            f"# PKI",
            f'root_ca_vm_id           = {root_ca.get("vm_id", 201)}',
            f'root_ca_ipv4_address    = {_hcl_str(root_addr)}',
            f'root_ca_ipv4_gateway    = {_hcl_str(root_net["gateway"])}',
            f'root_ca_bridge          = "{root_net["bridge"]}"',
            f'issuing_ca_ct_id        = {iss_ca.get("ct_id", 202)}',
            f'issuing_ca_ipv4_address = {_hcl_str(iss_addr)}',
            f'issuing_ca_ipv4_gateway = {_hcl_str(iss_net["gateway"])}',
            f'issuing_ca_bridge       = "{iss_net["bridge"]}"',
            f'cloud_init_template_id  = {root_ca.get("cloud_init_template_id", 9000)}',
        ]

    # DNS section — only emitted when services.dns is present in config
    dns = svcs.get("dns", {})
    if dns:
        auth = dns.get("auth", {})
        dist = dns.get("dist", {})

        auth_addr = auth.get("ip", "")
        dist_addr = dist.get("ip", "")

        validate_cidr(auth_addr, "services.dns.auth.ip")
        validate_cidr(dist_addr, "services.dns.dist.ip")

        auth_net = resolve_network(auth, networks, default_network, "dns.auth")
        dist_net = resolve_network(dist, networks, default_network, "dns.dist")

        lines += [
            f"",
            f"# DNS",
            f'dns_auth_ct_id        = {auth.get("ct_id", 103)}',
            f'dns_auth_ipv4_address = {_hcl_str(auth_addr)}',
            f'dns_auth_ipv4_gateway = {_hcl_str(auth_net["gateway"])}',
            f'dns_auth_bridge       = "{auth_net["bridge"]}"',
            f'dns_dist_ct_id        = {dist.get("ct_id", 104)}',
            f'dns_dist_ipv4_address = {_hcl_str(dist_addr)}',
            f'dns_dist_ipv4_gateway = {_hcl_str(dist_net["gateway"])}',
            f'dns_dist_bridge       = "{dist_net["bridge"]}"',
        ]

    # Nexus section — only emitted when services.nexus is present in config
    nexus = svcs.get("nexus", {})
    if nexus:
        nexus_addr = nexus.get("ip", "")
        validate_cidr(nexus_addr, "services.nexus.ip")
        nexus_net = resolve_network(nexus, networks, default_network, "nexus")
        lines += [
            f"",
            f"# Nexus",
            f'nexus_ct_id        = {nexus.get("ct_id", 205)}',
            f'nexus_ipv4_address = {_hcl_str(nexus_addr)}',
            f'nexus_ipv4_gateway = {_hcl_str(nexus_net["gateway"])}',
            f'nexus_bridge       = "{nexus_net["bridge"]}"',
        ]

    # Log Server section — only emitted when services.log_server is present in config
    log_server = svcs.get("log_server", {})
    if log_server:
        log_server_addr = log_server.get("ip", "")
        validate_cidr(log_server_addr, "services.log_server.ip")
        log_server_net = resolve_network(log_server, networks, default_network, "log_server")
        lines += [
            f"",
            f"# Log Server",
            f'log_server_node         = "{log_server["node"]}"',
            f'log_server_ct_id        = {log_server.get("ct_id", 206)}',
            f'log_server_ipv4_address = {_hcl_str(log_server_addr)}',
            f'log_server_ipv4_gateway = {_hcl_str(log_server_net["gateway"])}',
            f'log_server_bridge       = "{log_server_net["bridge"]}"',
        ]

    return "\n".join(lines) + "\n"


def gen_inventory(cfg: dict, env: str) -> str:
    hosts_cfg = cfg.get("hosts", {}) or {}
    ssh = cfg.get("ssh", {})
    svcs = cfg.get("services", {}) or {}
    default_user = ssh.get("default_user", "ubuntu")
    domain_name = cfg.get("domain_name", "")
    validate_domain_name(domain_name, "domain_name")
    infra = cfg.get("infrastructure", {})
    networks = infra.get("networks", {})
    default_network = infra.get("default_network")

    # nexus_apt_proxy — base Nexus URL emitted into all.vars so roles can construct
    # per-repo URLs (e.g. {{ nexus_apt_proxy }}/repository/apt-proxy-trixie/).
    # Phase 2 (tls: false): http://<ip>:8081  — plain HTTP, before PKI is deployed.
    # Phase 5+ (tls: true): https://<fqdn>:8443 — nginx TLS, requires fqdn to be set.
    # Empty string when Nexus is not enabled — roles skip proxy config when falsy.
    nexus_svc = svcs.get("nexus", {})
    nexus_enabled = bool(nexus_svc.get("enabled", False))
    nexus_ip = _strip_prefix(nexus_svc.get("ip", "")) if nexus_enabled else ""
    nexus_tls = bool(nexus_svc.get("tls", False)) if nexus_enabled else False
    nexus_fqdn_raw = nexus_svc.get("fqdn", "") if nexus_enabled else ""
    if nexus_tls and nexus_fqdn_raw:
        nexus_apt_proxy = f"https://{nexus_fqdn_raw}:8443"
    elif nexus_ip:
        nexus_apt_proxy = f"http://{nexus_ip}:8081"
    else:
        nexus_apt_proxy = ""

    lines = [
        f"# Generated by scripts/generate-configs.py from config/{env}.yml",
        f"# DO NOT EDIT — add hosts to config/{env}.yml and run `make configure`.",
        f"",
        f"all:",
        f"  vars:",
        f"    ansible_user: {default_user}",
    ]
    if domain_name:
        lines.append(f"    domain_name: {domain_name}")
    lines.append(f"    nexus_apt_proxy: \"{nexus_apt_proxy}\"")
    lines.append(f"  children:")

    has_content = bool(svcs) or any(v for v in hosts_cfg.values())

    if not has_content:
        lines.append(f"    {env}:")
        lines.append(f"      hosts: {{}}")
    else:
        # Auto-derive inventory groups from services:
        # - Flat service (has top-level 'ip'): one group, one host
        # - Nested service (sub-dicts each with 'ip'): one group per sub-host
        for svc_name, svc in svcs.items():
            if not isinstance(svc, dict):
                continue
            if "ip" in svc:
                # Flat service (e.g. minio)
                hostname = svc.get("hostname", f"{svc_name}-server")
                host_ip  = _strip_prefix(svc["ip"])
                lines.append(f"    {svc_name}:")
                # minio: propagate TLS config as group vars so role defaults stay deployment-agnostic
                if svc_name == "minio":
                    minio_tls = svc.get("tls", False)
                    minio_fqdn = svc.get("fqdn", "")
                    # minio_ca_url: use domain-based CA URL — DNS is required to be deployed
                    # before the TLS phase, so ca.<domain> is resolvable by this point.
                    # IP-based URL cannot work because the CA cert has only DNS SANs.
                    lines.append(f"      vars:")
                    lines.append(f"        minio_tls_enabled: {str(bool(minio_tls)).lower()}")
                    if minio_fqdn:
                        lines.append(f"        minio_domain: {minio_fqdn}")
                    if domain_name:
                        lines.append(f"        minio_ca_url: https://ca.{domain_name}")
                # nexus: propagate domain, CA URL, and APT proxy repo list
                elif svc_name == "nexus":
                    nexus_fqdn = svc.get("fqdn", "")
                    nexus_tls = svc.get("tls", False)
                    apt_proxy_repos = svc.get("apt_proxy_repos", [])
                    if nexus_enabled:
                        validate_nexus_apt_proxy_repos(apt_proxy_repos, "services.nexus.apt_proxy_repos")
                    lines.append(f"      vars:")
                    lines.append(f"        nexus_tls_enabled: {str(bool(nexus_tls)).lower()}")
                    if nexus_fqdn:
                        lines.append(f"        nexus_domain: {nexus_fqdn}")
                    if domain_name:
                        lines.append(f"        nexus_ca_url: https://ca.{domain_name}")
                    if apt_proxy_repos:
                        lines.append(f"        nexus_apt_proxy_repos:")
                        for repo in apt_proxy_repos:
                            entry = f'{{name: "{repo["name"]}", remote_url: "{repo["remote_url"]}", distribution: "{repo["distribution"]}"'
                            if repo.get("flat") is True:
                                entry += ", flat: true"
                            entry += "}"
                            lines.append(f"          - {entry}")
                    else:
                        lines.append(f"        nexus_apt_proxy_repos: []")
                elif svc_name == "log_server":
                    minio_svc = svcs.get("minio", {})
                    minio_tls = minio_svc.get("tls", False)
                    minio_fqdn = minio_svc.get("fqdn", "")
                    minio_ip = _strip_prefix(minio_svc.get("ip", ""))
                    minio_port = minio_svc.get("port", 9000)
                    if minio_tls and minio_fqdn:
                        otelcol_endpoint = f"https://{minio_fqdn}:{minio_port}"
                    elif minio_ip:
                        otelcol_endpoint = f"http://{minio_ip}:{minio_port}"
                    else:
                        otelcol_endpoint = ""
                    if otelcol_endpoint:
                        lines.append(f"      vars:")
                        lines.append(f"        otelcol_minio_endpoint: \"{otelcol_endpoint}\"")
                    else:
                        print(
                            "ERROR: services.log_server is present but otelcol_minio_endpoint "
                            "cannot be derived — set services.minio.ip (or services.minio.fqdn "
                            "when tls: true) in config/<env>.yml and re-run make configure.",
                            file=sys.stderr,
                        )
                        sys.exit(1)
                lines.append(f"      hosts:")
                lines.append(f"        {hostname}:")
                lines.append(f"          ansible_host: {host_ip}")
                if "ansible_user" in svc:
                    lines.append(f"          ansible_user: {svc['ansible_user']}")
            else:
                # Nested service (e.g. pki with root_ca / issuing_ca sub-hosts)
                for subkey, sub in svc.items():
                    if not isinstance(sub, dict) or "ip" not in sub:
                        continue
                    group    = f"{svc_name}_{subkey}"
                    hostname = sub.get("hostname", subkey)
                    host_ip  = _strip_prefix(sub["ip"])
                    lines.append(f"    {group}:")
                    # NOTE: each group may emit at most one `vars:` block.
                    # If a group needs additional vars in the future, extend the
                    # existing block here rather than adding a second `vars:` key
                    # (duplicate YAML mapping keys produce invalid inventory).
                    if group == "dns_dist":
                        auth_sub = svc.get("auth", {})
                        recursor_ip = _strip_prefix(auth_sub.get("ip", ""))
                        dist_net = resolve_network(sub, networks, default_network, "dns.dist")
                        network_cidr = dist_net["cidr"]
                        client_cidrs = sub.get("client_cidrs", [])
                        seen_cidrs: list[str] = []
                        for cidr in [network_cidr] + list(client_cidrs):
                            if cidr not in seen_cidrs:
                                seen_cidrs.append(cidr)
                        lines.append(f"      vars:")
                        lines.append(f"        pdns_recursor_address: {recursor_ip}")
                        lines.append(f"        pdns_dnsdist_acl_cidrs:")
                        for cidr in seen_cidrs:
                            lines.append(f'          - "{cidr}"')
                    if group == "dns_auth":
                        _dns_records = _derive_dns_records(cfg.get("services", {}))
                        lines.append(f"      vars:")
                        if _dns_records:
                            lines.append(f"        dns_records:")
                            for r in _dns_records:
                                lines.append(f'          - {{name: "{r["name"]}", ip: "{r["ip"]}", ttl: {r["ttl"]}}}')
                        else:
                            lines.append(f"        dns_records: []")
                    lines.append(f"      hosts:")
                    lines.append(f"        {hostname}:")
                    lines.append(f"          ansible_host: {host_ip}")
                    if "ansible_user" in sub:
                        lines.append(f"          ansible_user: {sub['ansible_user']}")

        # Manual/ad-hoc hosts
        for group, members in hosts_cfg.items():
            lines.append(f"    {group}:")
            if not members:
                lines.append(f"      hosts: {{}}")
            else:
                lines.append(f"      hosts:")
                for hostname, hostvars in (members or {}).items():
                    lines.append(f"        {hostname}:")
                    for k, v in (hostvars or {}).items():
                        lines.append(f"          {k}: {v}")

    return "\n".join(lines) + "\n"


def gen_allowed_cidrs(cfg: dict, env: str) -> str:
    infra = cfg.get("infrastructure", {})
    networks = infra.get("networks", {})
    default_network = infra.get("default_network")
    p = infra.get("proxmox", {})
    nodes = infra.get("nodes", {})
    svcs = cfg.get("services", {}) or {}

    proxmox_cidr = f'{p.get("ip", "")}/32' if p.get("ip") else ""

    # Collect the set of network names actually used by deployed services
    used_network_names = set()
    for svc_name, svc in svcs.items():
        if not isinstance(svc, dict):
            continue
        if "ip" in svc:
            net_name = svc.get("network") or default_network
            resolve_network(svc, networks, default_network, svc_name)
            used_network_names.add(net_name)
        else:
            for subkey, sub in svc.items():
                if not isinstance(sub, dict) or "ip" not in sub:
                    continue
                net_name = sub.get("network") or default_network
                resolve_network(sub, networks, default_network, f"{svc_name}.{subkey}")
                used_network_names.add(net_name)

    lines = [
        f"# Generated by scripts/generate-configs.py from config/{env}.yml",
        f"# DO NOT EDIT — run `make configure` to regenerate.",
        f"# After changes, rebuild the container: make build",
        f"",
    ]
    seen = set()

    # Emit one CIDR per used network
    for net_name in sorted(used_network_names):
        if net_name not in networks:
            continue
        cidr = networks[net_name]["cidr"]
        validate_cidr(cidr, f"infrastructure.networks.{net_name}.cidr")
        if cidr and cidr not in seen:
            lines.append(cidr)
            seen.add(cidr)

    # Per-node IPs — one /32 per cluster node for Squid allowlist
    for node_name in sorted(nodes.keys()):
        node_ip = nodes[node_name].get("ip", "")
        if node_ip:
            node_cidr = f"{node_ip}/32"
            if node_cidr not in seen:
                lines.append(node_cidr)
                seen.add(node_cidr)

    # Proxmox /32 special case (unchanged)
    if proxmox_cidr and proxmox_cidr not in seen:
        lines.append(proxmox_cidr)
        seen.add(proxmox_cidr)

    return "\n".join(lines) + "\n"


def gen_envrc(cfg: dict, env: str) -> str:
    infra = cfg.get("infrastructure", {})
    p = infra.get("proxmox", {})
    svcs = cfg.get("services", {}) or {}
    m = svcs.get("minio", {})

    endpoint = (
        f'https://{p["ip"]}:{p.get("port", 8006)}'
        if p.get("ip") else CHANGE_ME
    )
    insecure = str(p.get("insecure", "true")).lower()
    minio_tls = m.get("tls", False)
    minio_fqdn = m.get("fqdn", "")
    if minio_tls and not minio_fqdn:
        print("ERROR: services.minio.tls is true but services.minio.fqdn is not set.", file=sys.stderr)
        sys.exit(1)
    if m.get("ip"):
        if minio_tls and minio_fqdn:
            minio_endpoint = f"https://{minio_fqdn}:{m.get('port', 9000)}"
        else:
            scheme = "https" if minio_tls else "http"
            minio_endpoint = f'{scheme}://{_strip_prefix(m["ip"])}:{m.get("port", 9000)}'
    else:
        minio_endpoint = CHANGE_ME

    return textwrap.dedent(f"""\
        # Generated by scripts/generate-configs.py from config/{env}.yml
        # DO NOT EDIT the non-secret values — run `make configure` to regenerate.
        # Fill in all CHANGE_ME secrets below manually. This is the single source for all secrets.

        # Proxmox — endpoint auto-populated from config, token is a secret
        export PROXMOX_VE_ENDPOINT="{endpoint}"
        export PROXMOX_VE_INSECURE="{insecure}"
        export PROXMOX_VE_API_TOKEN="{CHANGE_ME}"  # e.g. terraform@pve!claude-{env}=<uuid>

        # MinIO root credentials — used by Ansible (minio role) and bootstrap-minio.sh
        export MINIO_ROOT_USER="{CHANGE_ME}"      # MinIO root/admin username
        export MINIO_ROOT_PASSWORD="{CHANGE_ME}"  # MinIO root/admin password

        # MinIO scoped key — endpoint auto-populated; keys from: bash scripts/bootstrap-minio.sh {env}
        export MINIO_ENDPOINT="{minio_endpoint}"
        export MINIO_ACCESS_KEY="{CHANGE_ME}"  # terraform-{env} scoped key (read/write tfstate-{env} only)
        export MINIO_SECRET_KEY="{CHANGE_ME}"  # terraform-{env} scoped secret

        # step-ca PKI passwords — used by Ansible pki-setup.yml playbook
        export STEP_CA_ROOT_PASSWORD="{CHANGE_ME}"          # password protecting the Root CA private key
        export STEP_CA_ISSUING_PASSWORD="{CHANGE_ME}"       # password protecting the Issuing CA private key
        export STEP_CA_LXC_ROOT_PASSWORD="{CHANGE_ME}"      # root account password for the Issuing CA LXC
        export STEP_CA_PROVISIONER_PASSWORD="{CHANGE_ME}"   # JWK provisioner password (used by minio TLS setup)

        # PowerDNS API keys — used by Ansible dns-setup.yml / dns-dist-setup.yml playbooks
        export PDNS_AUTH_API_KEY="{CHANGE_ME}"          # Auth webserver/API key
        export PDNS_RECURSOR_API_KEY="{CHANGE_ME}"      # Recursor webserver/API key
        export PDNS_DNSDIST_API_KEY="{CHANGE_ME}"       # DNSdist webserver/API key

        # Nexus credentials — used by Ansible nexus-setup.yml playbook
        export NEXUS_ADMIN_PASSWORD="{CHANGE_ME}"   # Nexus admin account password
        export NEXUS_READER_PASSWORD="{CHANGE_ME}"  # nexus-reader account (read-only APT/artifact access)

        # OTel Collector credentials — used by Ansible log-server-setup.yml playbook
        export OTELCOL_MINIO_ACCESS_KEY="{CHANGE_ME}"  # write-scoped key for otelcol-logs bucket
        export OTELCOL_MINIO_SECRET_KEY="{CHANGE_ME}"  # write-scoped secret

        # Internal CA trust — uncomment after PKI setup (.pki/root_ca.crt exists)
        # Go (Terraform) and curl pick this up; no container rebuild needed.
        # export SSL_CERT_FILE=/workspace/.pki/root_ca.crt

    """)


def gen_pki_group_vars(cfg: dict, env: str) -> tuple[str, str]:
    """Return (root_ca_vars_content, issuing_ca_vars_content) for PKI group_vars files."""
    svcs = cfg.get("services", {}) or {}
    pki = svcs.get("pki", {}) or {}
    domain_name = cfg.get("domain_name", "")

    root_ca = pki.get("root_ca", {}) or {}
    issuing_ca = pki.get("issuing_ca", {}) or {}

    root_ca_name = root_ca.get("ca_name", "Homelab Root CA")
    issuing_ca_name = issuing_ca.get("ca_name", "Homelab Issuing CA")
    issuing_ca_dns = f"ca.{domain_name}" if domain_name else "ca.example.com"

    root_vars = textwrap.dedent(f"""\
        # Generated by scripts/generate-configs.py from config/{env}.yml
        # DO NOT EDIT — run `make configure` to regenerate.
        step_ca_root_ca_name: "{root_ca_name}"
    """)

    issuing_vars = textwrap.dedent(f"""\
        # Generated by scripts/generate-configs.py from config/{env}.yml
        # DO NOT EDIT — run `make configure` to regenerate.
        step_ca_issuing_ca_name: "{issuing_ca_name}"
        step_ca_issuing_ca_dns: "{issuing_ca_dns}"
        step_ca_issuing_ca_address: ":443"
    """)

    return root_vars, issuing_vars


def gen_env_mk(cfg: dict, env: str) -> str:
    t = cfg.get("terraform", {})
    bucket = t.get("state_bucket", f"tfstate-{env}")
    return textwrap.dedent(f"""\
        # Generated by scripts/generate-configs.py from config/{env}.yml
        # DO NOT EDIT — run `make configure` to regenerate.
        ENV         := {env}
        TF_BUCKET   := {bucket}
        TF_VARFILE  := {env}.tfvars
        TF_PLANFILE := {env}.tfplan
    """)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    args = sys.argv[1:]
    force = "--force" in args
    args = [a for a in args if not a.startswith("--")]

    if not args:
        env = "sandbox"
    elif len(args) == 1:
        env = args[0]
    else:
        print(f"Usage: generate-configs.py [sandbox|production] [--force]", file=sys.stderr)
        sys.exit(1)

    print(f"Generating config for environment: {env}")

    cfg = load_config(env)

    # Validate schema before generating any files
    validate_schema(cfg)

    # 1. terraform/<env>.tfvars
    tfvars_path = os.path.join(REPO_ROOT, "terraform", f"{env}.tfvars")
    write_file(tfvars_path, gen_tfvars(cfg, env), "tfvars")

    # 2. ansible/inventory/hosts.yml
    inventory_path = os.path.join(REPO_ROOT, "ansible", "inventory", "hosts.yml")
    write_file(inventory_path, gen_inventory(cfg, env), "inventory")

    # 3. .devcontainer/squid/allowed-cidrs.conf
    cidrs_path = os.path.join(REPO_ROOT, ".devcontainer", "squid", "allowed-cidrs.conf")
    write_file(cidrs_path, gen_allowed_cidrs(cfg, env), "allowed-cidrs")
    if is_inside_container():
        print()
        print("  WARNING: Running inside dev container.")
        print("           allowed-cidrs.conf was updated on disk, but the Squid proxy")
        print("           will NOT reflect changes until you exit, run `make build`,")
        print("           and reopen the dev container.")

    # 4. .envrc
    envrc_path = os.path.join(REPO_ROOT, ".envrc")
    envrc_content = gen_envrc(cfg, env)
    written = atomic_write(envrc_path, envrc_content, force=force)
    rel_envrc = os.path.relpath(envrc_path, REPO_ROOT)
    print(f"  wrote  {rel_envrc}")
    remaining = sum(
        1 for line in written.splitlines()
        if re.match(rf'^export \w+="{re.escape(CHANGE_ME)}"', line)
    )
    if remaining:
        print(f"  ACTION: Fill in {remaining} secret(s) in .envrc marked {CHANGE_ME!r}")

    # 5. .env.mk
    env_mk_path = os.path.join(REPO_ROOT, ".env.mk")
    write_file(env_mk_path, gen_env_mk(cfg, env), ".env.mk")

    # 6. ansible/inventory/group_vars/pki_*/vars.yml
    root_vars, issuing_vars = gen_pki_group_vars(cfg, env)
    write_file(
        os.path.join(REPO_ROOT, "ansible", "inventory", "group_vars", "pki_root_ca", "vars.yml"),
        root_vars, "pki_root_ca vars",
    )
    write_file(
        os.path.join(REPO_ROOT, "ansible", "inventory", "group_vars", "pki_issuing_ca", "vars.yml"),
        issuing_vars, "pki_issuing_ca vars",
    )

    print()
    print(f"Done. Next steps:")
    if remaining:
        print(f"  1. Fill in secrets in .envrc (API token, MinIO keys)")
        print(f"  2. Run: direnv allow")
        print(f"  3. Run: make init && make plan")
    else:
        print(f"  1. Run: make init && make plan")


if __name__ == "__main__":
    main()
