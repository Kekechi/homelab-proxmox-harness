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


def validate_domain_name(value: str, field: str):
    """Reject domain names with characters that would produce invalid YAML."""
    import re
    if value and not re.match(r'^[a-zA-Z0-9.-]+$', value):
        print(f"ERROR: {field} contains invalid characters. Only alphanumerics, dots, and hyphens are allowed.", file=sys.stderr)
        sys.exit(1)
        print(f"       Got: {value!r}", file=sys.stderr)
        sys.exit(1)


def _strip_prefix(addr: str) -> str:
    """Strip CIDR prefix: '10.0.0.1/24' → '10.0.0.1'."""
    return addr.split("/")[0] if addr else addr


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
]


def atomic_write(path: str, content: str, force: bool = False):
    """Write content atomically. For .envrc, warn if any secret has been filled in."""
    tmp = path + ".new"
    if os.path.exists(path) and not force:
        with open(path) as f:
            existing_lines = f.readlines()
        # Protect if ANY secret line has been changed away from the placeholder.
        # This allows partial fills (e.g. PVE token set, MinIO keys still CHANGE_ME).
        for line in existing_lines:
            for var in _ENVRC_SECRET_VARS:
                if var in line and CHANGE_ME not in line:
                    print(f"WARNING: {os.path.relpath(path, REPO_ROOT)} contains filled-in secrets.", file=sys.stderr)
                    print(f"         New content written to {os.path.relpath(tmp, REPO_ROOT)}", file=sys.stderr)
                    print(f"         Review the diff and merge manually, or re-run with --force to overwrite.", file=sys.stderr)
                    with open(tmp, "w") as f:
                        f.write(content)
                    return
    with open(tmp, "w") as f:
        f.write(content)
    os.rename(tmp, path)


def write_file(path: str, content: str, label: str):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(content)
    rel = os.path.relpath(path, REPO_ROOT)
    print(f"  wrote  {rel}")


# ---------------------------------------------------------------------------
# Generators
# ---------------------------------------------------------------------------

def _hcl_str(val: str) -> str:
    """Return HCL string literal, or null if value is empty."""
    return f'"{val}"' if val else "null"


def gen_tfvars(cfg: dict, env: str) -> str:
    infra = cfg.get("infrastructure", {})
    p = infra.get("proxmox", {})
    n = infra.get("network", {})
    s = infra.get("storage", {})
    t = cfg.get("terraform", {})
    ssh = cfg.get("ssh", {})
    svcs = cfg.get("services", {})
    pki = svcs.get("pki", {})

    vlan = n.get("vlan_id")
    vlan_line = f'vlan_id            = {vlan}' if vlan is not None else 'vlan_id            = null'

    pool_id = t.get("pool_id", "")
    pool_line = f'pool_id            = "{pool_id}"'

    cidr = n.get("cidr", "")
    cidr_line = f'network_cidr       = "{cidr}"' if cidr else 'network_cidr       = ""'

    ssh_key = ssh.get("public_key", "")

    domain_name = cfg.get("domain_name", "")

    lines = [
        f"# Generated by scripts/generate-configs.py from config/{env}.yml",
        f"# DO NOT EDIT — run `make configure` to regenerate.",
        f"",
        f'proxmox_node       = "{p.get("node", "")}"',
        pool_line,
        f'datastore_id           = "{s.get("datastore_id", "local-lvm")}"',
        f'cloudinit_datastore_id = "{s.get("cloudinit_datastore_id", "local")}"',
        f'bridge             = "{n.get("bridge", "vmbr0")}"',
        vlan_line,
        cidr_line,
        f'vm_id_range_start  = {t.get("vm_id_range_start", 200)}',
        f'clone_template_id  = {t.get("clone_template_id", 0)}',
        f'ssh_public_key     = "{ssh_key}"',
        f'domain_name        = {_hcl_str(domain_name)}',
    ]

    # PKI section — only emitted when services.pki is present in config
    if pki:
        root_ca  = pki.get("root_ca", {})
        iss_ca   = pki.get("issuing_ca", {})

        root_addr = root_ca.get("ip", "")
        root_gw   = root_ca.get("gateway", "")
        iss_addr  = iss_ca.get("ip", "")
        iss_gw    = iss_ca.get("gateway", "")
        lxc_tmpl  = iss_ca.get("lxc_template_file_id", "")

        lines += [
            f"",
            f"# PKI",
            f'root_ca_vm_id           = {root_ca.get("vm_id", 201)}',
            f'root_ca_ipv4_address    = {_hcl_str(root_addr)}',
            f'root_ca_ipv4_gateway    = {_hcl_str(root_gw)}',
            f'issuing_ca_ct_id        = {iss_ca.get("ct_id", 202)}',
            f'issuing_ca_ipv4_address = {_hcl_str(iss_addr)}',
            f'issuing_ca_ipv4_gateway = {_hcl_str(iss_gw)}',
            f'cloud_init_template_id  = {root_ca.get("cloud_init_template_id", 9000)}',
            f'lxc_template_file_id    = {_hcl_str(lxc_tmpl)}',
        ]

    return "\n".join(lines) + "\n"


def gen_inventory(cfg: dict, env: str) -> str:
    hosts_cfg = cfg.get("hosts", {}) or {}
    ssh = cfg.get("ssh", {})
    svcs = cfg.get("services", {}) or {}
    default_user = ssh.get("default_user", "ubuntu")
    domain_name = cfg.get("domain_name", "")
    validate_domain_name(domain_name, "domain_name")

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
    n = infra.get("network", {})
    p = infra.get("proxmox", {})
    svcs = cfg.get("services", {}) or {}
    minio = svcs.get("minio", {})

    cidr = n.get("cidr", "")
    proxmox_cidr = f'{p.get("ip", "")}/32' if p.get("ip") else ""
    minio_cidr   = f'{_strip_prefix(minio.get("ip", ""))}/32' if minio.get("ip") else ""

    validate_cidr(cidr, "infrastructure.network.cidr")

    lines = [
        f"# Generated by scripts/generate-configs.py from config/{env}.yml",
        f"# DO NOT EDIT — run `make configure` to regenerate.",
        f"# After changes, rebuild the container: make build",
        f"",
    ]
    seen = set()
    for entry in [cidr, minio_cidr, proxmox_cidr]:
        if entry and entry not in seen:
            lines.append(entry)
            seen.add(entry)
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
    minio_endpoint = (
        f'http://{_strip_prefix(m["ip"])}:{m.get("port", 9000)}'
        if m.get("ip") else CHANGE_ME
    )

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
        export STEP_CA_ROOT_PASSWORD="{CHANGE_ME}"     # password protecting the Root CA private key
        export STEP_CA_ISSUING_PASSWORD="{CHANGE_ME}"  # password protecting the Issuing CA private key
        export STEP_CA_LXC_ROOT_PASSWORD="{CHANGE_ME}" # root account password for the Issuing CA LXC

    """)


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
    atomic_write(envrc_path, envrc_content, force=force)
    rel_envrc = os.path.relpath(envrc_path, REPO_ROOT)
    if os.path.exists(envrc_path + ".new"):
        pass  # warning already printed by atomic_write
    else:
        print(f"  wrote  {rel_envrc}")
        # Check if secrets still need to be filled
        with open(envrc_path) as f:
            content = f.read()
        if CHANGE_ME in content:
            remaining = content.count(CHANGE_ME)
            print(f"  ACTION: Fill in {remaining} secret(s) in .envrc marked {CHANGE_ME!r}")

    # 5. .env.mk
    env_mk_path = os.path.join(REPO_ROOT, ".env.mk")
    write_file(env_mk_path, gen_env_mk(cfg, env), ".env.mk")

    print()
    print(f"Done. Next steps:")
    if CHANGE_ME in gen_envrc(cfg, env):
        print(f"  1. Fill in secrets in .envrc (API token, MinIO keys)")
        print(f"  2. Run: direnv allow")
        print(f"  3. Run: make init && make plan")
    else:
        print(f"  1. Run: make init && make plan")


if __name__ == "__main__":
    main()
