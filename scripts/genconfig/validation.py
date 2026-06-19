"""genconfig.validation — config schema + Nexus repo validation (exits on error)."""

import sys

from .helpers import validate_cidr


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
            "See docs/guides/cluster-setup.md for migration steps."
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


_NEXUS_REQUIRED_APT_REPOS = {
    "apt-proxy-trixie",
    "apt-proxy-trixie-security",
    "apt-proxy-trixie-updates",
    "apt-proxy-smallstep",
    "apt-proxy-powerdns-auth-50",
    "apt-proxy-powerdns-rec-54",
    "apt-proxy-dnsdist-21",
}


def validate_nexus_raw_hosted_repos(repos: list, field: str) -> None:
    """Validate raw hosted repo entries — each must be a dict with a name field."""
    _UNSAFE = {'"', "\n", "\r", "}", ","}
    for i, repo in enumerate(repos):
        if not isinstance(repo, dict):
            sys.exit(
                f"Config error: '{field}[{i}]' must be a mapping (got "
                f"{type(repo).__name__!r}). Each entry needs a name key."
            )
        name = repo.get("name", "")
        if not name:
            sys.exit(f"Config error: '{field}[{i}]' is missing required 'name' key.")
        if any(c in name for c in _UNSAFE):
            sys.exit(
                f"Config error: '{field}[{i}].name' contains a character not allowed "
                f"in generated YAML flow-mapping (\", }}, ,, or newline). Remove it and re-run."
            )


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
