"""genconfig.helpers — shared HCL/IP helpers, DNS-record derivation, file writers.

These are the cross-emitter primitives. The emitter contract (DO-NOT-EDIT
header, byte-stability, `_hcl_str` null-if-empty) is documented in
scripts/genconfig/emit/CLAUDE.md.
"""

import os
import re
import sys

from .config import CHANGE_ME, REPO_ROOT


def validate_cidr(value: str, field: str):
    """Reject bare IPs without a prefix length."""
    if value and "/" not in str(value):
        print(f"ERROR: {field} must use CIDR notation (e.g., 203.0.113.0/24 or 203.0.113.5/32).", file=sys.stderr)
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


def _hcl_str(val: str) -> str:
    """Return HCL string literal, or null if value is empty."""
    return f'"{val}"' if val else "null"


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
    "SPLUNK_ADMIN_PASSWORD",
    "SPLUNK_HEC_TOKEN",
    "SPLUNK_MCP_PASSWORD"
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

        # Never delete a key the generator did not emit this run: any export
        # line in the existing file whose variable is absent from the newly
        # generated content (operator-added, or from a since-disabled service)
        # is carried over verbatim instead of silently dropped.
        emitted_vars = set()
        for line in content.splitlines():
            m = re.match(r'^#?\s*export (\w+)=', line)
            if m:
                emitted_vars.add(m.group(1))
        carried = []
        for line in existing.splitlines():
            m = re.match(r'^export (\w+)=', line)
            if m and m.group(1) not in emitted_vars:
                carried.append(line)
        if carried:
            merged.append("")
            merged.append("# Preserved from the previous .envrc — keys the generator no longer emits.")
            merged.append("# Move these to .envrc.local (never touched by `make configure`).")
            merged.extend(carried)

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
