"""genconfig.emit.inventory — render ansible/inventory/hosts.yml.

Groups and hosts are derived generically from the discovered component
manifests (instances.<i>.group) plus the ad-hoc `hosts:` section. Only ENABLED
components appear in the inventory — a disabled component contributes no group,
no /etc/hosts entry, and no DNS record.

INTERIM cross-component couplings (dissolved into capability consumes/provides
in phase 4 of the component refactor) are quarantined in _coupling_vars below:
  - log_server reads services.minio (otelcol_minio_endpoint) and services.splunk
    (otelcol_splunk_hec_*).
  - dns dist reads its network CIDR + client_cidrs (pdns_dnsdist_acl_cidrs), the
    auth instance IP, and services.log_server.ip (dns_collector syslog wiring).
  - minio/nexus/splunk read domain_name for their CA URL.
  - _derive_dns_records feeds both common_internal_hosts (/etc/hosts) and the
    dns_auth A-records.
"""

import sys

from ..discovery import (
    component_order,
    discover_components,
    enabled_components,
    instance_config,
    instance_group,
)
from ..helpers import _derive_dns_records, _strip_prefix, resolve_network, validate_domain_name
from ..validation import validate_nexus_apt_proxy_repos, validate_nexus_raw_hosted_repos


def _coupling_vars(group: str, blk: dict, cfg: dict, enabled_svcs: dict,
                   networks: dict, default_network) -> list[str]:
    """INTERIM: per-group vars that reach across components (phase 4 replaces
    these with capability resolution). Returns YAML lines (6-space indent for
    keys under `vars:`), or [] when the group needs none."""
    domain_name = cfg.get("domain_name", "")
    lines: list[str] = []

    if group == "minio":
        minio_tls = blk.get("tls", False)
        minio_fqdn = blk.get("fqdn", "")
        # minio_ca_url: domain-based CA URL — DNS must be deployed before the TLS
        # phase, so ca.<domain> is resolvable by then. IP-based URLs cannot work
        # because the CA cert has only DNS SANs.
        lines.append(f"        minio_tls_enabled: {str(bool(minio_tls)).lower()}")
        if minio_fqdn:
            lines.append(f"        minio_domain: {minio_fqdn}")
        if domain_name:
            lines.append(f"        minio_ca_url: https://ca.{domain_name}")
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
        raw_hosted_repos = blk.get("raw_hosted_repos", [])
        if raw_hosted_repos:
            validate_nexus_raw_hosted_repos(raw_hosted_repos, "services.nexus.raw_hosted_repos")
            lines.append(f"        nexus_raw_hosted_repos:")
            for repo in raw_hosted_repos:
                lines.append(f'          - {{name: "{repo["name"]}"}}')
        else:
            lines.append(f"        nexus_raw_hosted_repos: []")

    elif group == "log_server":
        minio_svc = enabled_svcs.get("minio", {})
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
        if not otelcol_endpoint:
            print(
                "ERROR: services.log_server is enabled but otelcol_minio_endpoint "
                "cannot be derived — enable services.minio with an ip (or fqdn when "
                "tls: true) in config/<env>.yml and re-run make configure.",
                file=sys.stderr,
            )
            sys.exit(1)
        splunk_svc = enabled_svcs.get("splunk", {})
        splunk_ip = _strip_prefix(splunk_svc.get("ip", ""))
        splunk_hec_port = splunk_svc.get("hec_port", 8088)
        # Splunk HEC sink only when Splunk is ENABLED with an IP (deprecation-
        # planned; default sink is MinIO awss3).
        splunk_hec_on = bool(splunk_ip)
        lines.append(f"        otelcol_minio_endpoint: \"{otelcol_endpoint}\"")
        lines.append(f"        otelcol_splunk_hec_enabled: {str(splunk_hec_on).lower()}")
        if splunk_hec_on:
            lines.append(f"        otelcol_splunk_hec_url: \"http://{splunk_ip}:{splunk_hec_port}\"")

    elif group == "splunk":
        splunk_tls = blk.get("tls", False)
        splunk_fqdn = blk.get("fqdn", "")
        lines.append(f"        splunk_tls_enabled: {str(bool(splunk_tls)).lower()}")
        if splunk_fqdn:
            lines.append(f"        splunk_domain: {splunk_fqdn}")
        if domain_name:
            lines.append(f"        splunk_ca_url: https://ca.{domain_name}")

    elif group == "dns_dist":
        auth_blk = (enabled_svcs.get("dns", {}) or {}).get("auth", {})
        recursor_ip = _strip_prefix(auth_blk.get("ip", ""))
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
        log_server_ip = _strip_prefix(enabled_svcs.get("log_server", {}).get("ip", ""))
        # When log_server is enabled, wire dns_dist → log_server syslog pipeline.
        if log_server_ip:
            lines.append(f'        dns_collector_syslog_endpoint: "{log_server_ip}"')
            lines.append(f"        pdns_dnsdist_dnstap_enabled: true")

    elif group == "dns_auth":
        _dns_records = _derive_dns_records(enabled_svcs)
        if _dns_records:
            lines.append(f"        dns_records:")
            for r in _dns_records:
                lines.append(f'          - {{name: "{r["name"]}", ip: "{r["ip"]}", ttl: {r["ttl"]}}}')
        else:
            lines.append(f"        dns_records: []")

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

    # nexus_apt_proxy — base Nexus URL emitted into all.vars so roles can construct
    # per-repo URLs. Phase 2 (tls: false): http://<ip>:8081. Phase 5+ (tls: true):
    # https://<fqdn>:8443. Empty when Nexus is not enabled — roles skip proxy
    # config when falsy.
    nexus_svc = enabled_svcs.get("nexus", {})
    nexus_ip = _strip_prefix(nexus_svc.get("ip", ""))
    nexus_tls = bool(nexus_svc.get("tls", False))
    nexus_fqdn_raw = nexus_svc.get("fqdn", "")
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
    # nexus_fallback — phase-keyed run parameter, NOT per-env config. Shared
    # default 'fail' is fail-safe: when Nexus is unreachable a deploy aborts with
    # a clear message rather than silently chasing upstream. Bootstrap tooling
    # overrides with `-e nexus_fallback=upstream` (Nexus does not exist yet at
    # the PKI phase). See docs/design/apt-fallback-policy.md.
    lines.append(f"    nexus_fallback: \"fail\"")
    log_server_ip_for_all = _strip_prefix(enabled_svcs.get("log_server", {}).get("ip", ""))
    if log_server_ip_for_all:
        lines.append(f'    common_log_server_address: "{log_server_ip_for_all}"')
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
                # NOTE: each group emits at most one `vars:` block — extend
                # _coupling_vars rather than adding a second `vars:` key.
                coupling = _coupling_vars(group, blk, cfg, enabled_svcs, networks, default_network)
                if coupling:
                    lines.append(f"      vars:")
                    lines += coupling
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
