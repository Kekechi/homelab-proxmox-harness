"""genconfig.emit.inventory — render ansible/inventory/hosts.yml.

Groups and hosts are derived generically from the discovered component
manifests (instances.<i>.group) plus the ad-hoc `hosts:` section. Only ENABLED
components appear in the inventory — a disabled component contributes no group,
no /etc/hosts entry, and no DNS record.

Cross-component values arrive via CAPABILITY RESOLUTION (see
genconfig/capabilities.py): each instance's manifest consumes: block names the
vars injected into its group; CORE_CONSUMES feeds all.vars for the shared
common role. _self_vars below holds only vars derived from a component's OWN
config (TLS flags, its FQDN, its ACL) — never a reach into another component.
"""

import sys

from ..discovery import (
    component_order,
    discover_components,
    enabled_components,
    instance_config,
    instance_group,
)
from ..capabilities import CORE_CONSUMES, build_providers, resolve_consumes
from ..helpers import _derive_dns_records, _strip_prefix, resolve_network, validate_domain_name
from ..validation import validate_nexus_apt_proxy_repos, validate_nexus_raw_hosted_repos


def _self_vars(group: str, blk: dict, cfg: dict, enabled_svcs: dict,
               networks: dict, default_network) -> list[str]:
    """Per-group vars derived from the component's OWN config only. Anything
    that reaches into another component goes through capability resolution."""
    lines: list[str] = []

    if group == "minio":
        minio_tls = blk.get("tls", False)
        minio_fqdn = blk.get("fqdn", "")
        lines.append(f"        minio_tls_enabled: {str(bool(minio_tls)).lower()}")
        if minio_fqdn:
            lines.append(f"        minio_domain: {minio_fqdn}")
        # Cert SAN coupling: the FQDN is the primary SAN; the bare IP is a
        # secondary SAN so IP-addressed access still validates.
        lines.append(f"        minio_endpoint_ip: {_strip_prefix(blk['ip'])}")

    elif group == "nexus":
        nexus_fqdn = blk.get("fqdn", "")
        nexus_tls = blk.get("tls", False)
        apt_proxy_repos = blk.get("apt_proxy_repos", [])
        validate_nexus_apt_proxy_repos(apt_proxy_repos, "services.nexus.apt_proxy_repos")
        lines.append(f"        nexus_tls_enabled: {str(bool(nexus_tls)).lower()}")
        if nexus_fqdn:
            lines.append(f"        nexus_domain: {nexus_fqdn}")
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
        raw_hosted_repos = blk.get("raw_hosted_repos", [])
        if raw_hosted_repos:
            validate_nexus_raw_hosted_repos(raw_hosted_repos, "services.nexus.raw_hosted_repos")
            lines.append(f"        nexus_raw_hosted_repos:")
            for repo in raw_hosted_repos:
                lines.append(f'          - {{name: "{repo["name"]}"}}')
        else:
            lines.append(f"        nexus_raw_hosted_repos: []")

    elif group == "splunk":
        splunk_tls = blk.get("tls", False)
        splunk_fqdn = blk.get("fqdn", "")
        lines.append(f"        splunk_tls_enabled: {str(bool(splunk_tls)).lower()}")
        if splunk_fqdn:
            lines.append(f"        splunk_domain: {splunk_fqdn}")

    elif group == "dns_dist":
        auth_blk = (enabled_svcs.get("dns", {}) or {}).get("auth", {})
        recursor_ip = _strip_prefix(auth_blk.get("ip", ""))  # sibling instance — same component
        dist_net = resolve_network(blk, networks, default_network, "dns.dist")
        network_cidr = dist_net["cidr"]
        client_cidrs = blk.get("client_cidrs", [])
        seen_cidrs: list[str] = []
        for cidr in [network_cidr] + list(client_cidrs):
            if cidr not in seen_cidrs:
                seen_cidrs.append(cidr)
        lines.append(f"        pdns_recursor_address: {recursor_ip}")
        lines.append(f"        pdns_dnsdist_acl_cidrs:")
        for cidr in seen_cidrs:
            lines.append(f'          - "{cidr}"')

    return lines


def _capability_var_lines(cap_vars: dict) -> list[str]:
    """Render capability-resolved vars (sorted by name) as group-var lines."""
    lines: list[str] = []
    for var in sorted(cap_vars):
        val = cap_vars[var]
        if isinstance(val, bool):
            lines.append(f"        {var}: {str(val).lower()}")
        elif isinstance(val, list):
            if not val:
                lines.append(f"        {var}: []")
                continue
            lines.append(f"        {var}:")
            for item in val:
                if isinstance(item, dict):
                    inner = ", ".join(
                        f'{k}: "{v}"' if isinstance(v, str) else f"{k}: {v}"
                        for k, v in item.items()
                    )
                    lines.append(f"          - {{{inner}}}")
                else:
                    lines.append(f'          - "{item}"')
        else:
            lines.append(f'        {var}: "{val}"')
    return lines


def gen_inventory(cfg: dict, env: str, components: dict | None = None) -> str:
    hosts_cfg = cfg.get("hosts", {}) or {}
    ssh = cfg.get("ssh", {})
    svcs = cfg.get("services", {}) or {}
    default_user = ssh.get("default_user", "ubuntu")
    domain_name = cfg.get("domain_name", "")
    validate_domain_name(domain_name, "domain_name")
    infra = cfg.get("infrastructure", {})
    networks = infra.get("networks", {})
    default_network = infra.get("default_network")

    components = components or discover_components()
    enabled = enabled_components(components, cfg)
    enabled_svcs = {name: svcs[name] for name in enabled}

    # Capability resolution: cross-component values for group vars + all.vars.
    providers = build_providers(cfg, components)
    cap_group_vars, core_vars = resolve_consumes(cfg, components, providers, CORE_CONSUMES)
    # apt.source consumed by the common role on every host; "" when no provider.
    nexus_apt_proxy = core_vars.get("nexus_apt_proxy", "")

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
    # nexus_fallback — phase-keyed run parameter, NOT per-env config. Shared
    # default 'fail' is fail-safe: when Nexus is unreachable a deploy aborts with
    # a clear message rather than silently chasing upstream. Bootstrap tooling
    # overrides with `-e nexus_fallback=upstream` (Nexus does not exist yet at
    # the PKI phase). See docs/design/apt-fallback-policy.md.
    lines.append(f"    nexus_fallback: \"fail\"")
    if core_vars.get("common_log_server_address"):
        lines.append(f'    common_log_server_address: "{core_vars["common_log_server_address"]}"')
    # Internal service FQDN → IP map for /etc/hosts (the common role writes these).
    # Decouples cold-start TLS from the internal DNS server. Only ENABLED
    # components resolve; honours dns_name/dns_aliases overrides and dns: false.
    if domain_name:
        internal_hosts = _derive_dns_records(enabled_svcs)
        if internal_hosts:
            lines.append(f"    common_internal_hosts:")
            for rec in internal_hosts:
                lines.append(f'      - {{ip: "{rec["ip"]}", fqdn: "{rec["name"]}.{domain_name}"}}')
    lines.append(f"  children:")

    has_content = bool(enabled) or any(v for v in hosts_cfg.values())

    if not has_content:
        lines.append(f"    {env}:")
        lines.append(f"      hosts: {{}}")
    else:
        for comp in sorted(enabled.values(), key=component_order):
            manifest = comp["manifest"]
            name = manifest["name"]
            instances = manifest["instances"]
            single = len(instances) == 1
            for iname, inst in instances.items():
                blk = instance_config(cfg, comp, iname)
                if "ip" not in blk:
                    continue  # nothing to inventory without an address
                group = instance_group(name, iname, inst, single)
                hostname = blk.get("hostname") or (name if single else iname)
                host_ip = _strip_prefix(blk["ip"])
                lines.append(f"    {group}:")
                # NOTE: each group emits at most one `vars:` block — self vars
                # first, then capability-resolved vars (sorted).
                var_lines = _self_vars(group, blk, cfg, enabled_svcs, networks, default_network)
                var_lines += _capability_var_lines(cap_group_vars.get(group, {}))
                if var_lines:
                    lines.append(f"      vars:")
                    lines += var_lines
                lines.append(f"      hosts:")
                lines.append(f"        {hostname}:")
                lines.append(f"          ansible_host: {host_ip}")
                if "ansible_user" in blk:
                    lines.append(f"          ansible_user: {blk['ansible_user']}")

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
