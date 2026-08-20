"""genconfig.capabilities — capability-contract resolution (consumes/provides).

Dependencies between components are keyed by CAPABILITY, never component name —
a consumer cannot know whether its provider is public or private, one or many.

Manifest declarations (per instance):

  provides:
    - capability: s3.endpoint
      value: "http://{ip}:{port}"        # template over the instance's merged config
      value_tls: "https://{fqdn}:{port}" # used instead when the instance has tls: true
      priority: 10                        # optional tie-break for single-valued caps

  consumes:
    otelcol_minio_endpoint: {capability: s3.endpoint}            # hard
    otelcol_splunk_hec_url:                                       # optional
      capability: splunk.hec
      optional: true
      also_set: {otelcol_splunk_hec_enabled: true}  # flags set only on resolution

Template pseudo-fields (beyond any scalar in the instance's merged config):
  {ip} bare address, {ip_cidr} as configured, {domain} global domain_name,
  {scheme} https-if-tls, {host} fqdn-if-tls-else-bare-ip.

Semantics (design record §5):
  - hard consume unresolved while the consumer is enabled  → validation error
  - optional consume unresolved → the var simply does not exist (roles gate on
    `is defined` or their defaults); no dummy values
  - many: true aggregates every enabled provider into a list
  - two providers of a single-valued capability → error, unless priorities
    break the tie deliberately (highest wins)
  - dns.record is provided IMPLICITLY by every enabled instance with an ip
    (honouring dns:/dns_name:/dns_aliases:) — the reverse direction that lets
    the DNS component template its zone from whatever exists.

Re-convergence: the resolved provider set is snapshotted (gitignored state
file); when it changes, every consumer of a changed capability is stale and
the generator prints the re-run list.
"""

import json
import os
import sys

from .config import REPO_ROOT
from .discovery import enabled_components, instance_config, instance_group
from .helpers import _derive_dns_records, _strip_prefix

_STATE_FILE = os.path.join(REPO_ROOT, ".genconfig-capabilities.json")


def _render_value(prov: dict, blk: dict, cfg: dict, where: str) -> str:
    tls = bool(blk.get("tls", False))
    template = prov.get("value_tls") if (tls and prov.get("value_tls")) else prov.get("value")
    if template is None:
        sys.exit(f"Component error: provides entry {prov.get('capability')} in {where} has no value template.")
    ip_cidr = blk.get("ip", "")
    fields = {k: v for k, v in blk.items() if isinstance(v, (str, int, float, bool))}
    fields.update({
        "ip": _strip_prefix(ip_cidr),
        "ip_cidr": ip_cidr,
        "domain": cfg.get("domain_name", ""),
        "scheme": "https" if tls else "http",
        "host": blk.get("fqdn") if (tls and blk.get("fqdn")) else _strip_prefix(ip_cidr),
    })
    try:
        return template.format(**fields)
    except KeyError as e:
        sys.exit(
            f"Component error: provides template {template!r} in {where} references "
            f"unknown field {e} (available: config scalars + ip/ip_cidr/domain/scheme/host)."
        )


def build_providers(cfg: dict, components: dict) -> dict:
    """{capability: [{value, priority, component, instance}, ...]} for enabled components."""
    enabled = enabled_components(components, cfg)
    providers: dict = {}
    for name, comp in enabled.items():
        instances = comp["manifest"]["instances"]
        for iname, inst in instances.items():
            blk = instance_config(cfg, comp, iname)
            for prov in inst.get("provides") or []:
                cap = prov.get("capability")
                if not cap:
                    sys.exit(f"Component error: provides entry without capability in {name}.{iname}.")
                providers.setdefault(cap, []).append({
                    "value": _render_value(prov, blk, cfg, f"{name}.{iname}"),
                    "priority": prov.get("priority", 0),
                    "component": name,
                    "instance": iname,
                })

    # Implicit reverse-direction capability: every enabled instance with an ip
    # provides its own dns.record (label/aliases logic shared with the mesh).
    svcs = cfg.get("services", {}) or {}
    enabled_svcs = {n: svcs[n] for n in enabled if n in svcs}
    for rec in _derive_dns_records(enabled_svcs):
        providers.setdefault("dns.record", []).append({
            "value": rec,  # {name, ip, ttl}
            "priority": 0,
            "component": "(implicit)",
            "instance": rec["name"],
        })
    return providers


def resolve_consumes(cfg: dict, components: dict, providers: dict,
                     extra_consumes: dict | None = None) -> tuple[dict, dict]:
    """Resolve every enabled instance's consumes (and core-level extra_consumes).

    Returns (group_vars, core_vars):
      group_vars: {inventory_group: {var: value}}   (values may be lists for many:)
      core_vars:  {var: value} destined for all.vars
    """
    enabled = enabled_components(components, cfg)

    def _resolve_one(var: str, spec: dict, consumer_label: str):
        cap = spec.get("capability")
        if not cap:
            sys.exit(f"Component error: consumes '{var}' in {consumer_label} has no capability.")
        provs = providers.get(cap, [])
        if spec.get("many"):
            return [p["value"] for p in provs] if provs else ([] if not spec.get("optional") else None)
        if not provs:
            if spec.get("optional"):
                return spec.get("default", None) if "default" in spec else None
            sys.exit(
                f"Config error: {consumer_label} requires capability '{cap}' ({var}) "
                f"but no enabled component provides it."
            )
        if len(provs) > 1:
            top = sorted(provs, key=lambda p: -p["priority"])
            if top[0]["priority"] == top[1]["priority"]:
                who = ", ".join(f"{p['component']}.{p['instance']}" for p in provs)
                sys.exit(
                    f"Config error: capability '{cap}' is single-valued but provided by "
                    f"{who} with equal priority — disable one or set distinct priorities."
                )
            return top[0]["value"]
        return provs[0]["value"]

    group_vars: dict = {}
    for name, comp in enabled.items():
        instances = comp["manifest"]["instances"]
        single = len(instances) == 1
        for iname, inst in instances.items():
            consumes = inst.get("consumes") or {}
            if not consumes:
                continue
            group = instance_group(name, iname, inst, single)
            for var, spec in consumes.items():
                val = _resolve_one(var, spec, f"components/{name} ({iname})")
                if val is None:
                    continue  # optional and unresolved: the var does not exist
                group_vars.setdefault(group, {})[var] = val
                for flag, flag_val in (spec.get("also_set") or {}).items():
                    group_vars[group][flag] = flag_val

    core_vars: dict = {}
    for var, spec in (extra_consumes or {}).items():
        val = _resolve_one(var, spec, "core (all.vars)")
        if val is not None:
            core_vars[var] = val
    return group_vars, core_vars


def report_reconvergence(cfg: dict, components: dict, providers: dict) -> None:
    """Compare the provider set against the last snapshot; print the stale-consumer
    re-run list when a capability's provider set changed."""
    snapshot = {
        cap: sorted(f"{p['component']}.{p['instance']}:{p['value']}" for p in provs)
        for cap, provs in providers.items()
    }
    previous = {}
    if os.path.exists(_STATE_FILE):
        try:
            with open(_STATE_FILE) as f:
                previous = json.load(f)
        except (json.JSONDecodeError, OSError):
            previous = {}

    changed = sorted(
        cap for cap in set(snapshot) | set(previous)
        if snapshot.get(cap) != previous.get(cap)
    )
    if changed and previous:
        enabled = enabled_components(components, cfg)
        stale: dict = {}
        for cap in changed:
            for name, comp in enabled.items():
                for iname, inst in comp["manifest"]["instances"].items():
                    for spec in (inst.get("consumes") or {}).values():
                        if spec.get("capability") == cap:
                            stale.setdefault(name, set()).add(cap)
        print("  RE-CONVERGE: capability provider set changed:")
        for cap in changed:
            print(f"    - {cap}")
        if stale:
            print("  Stale consumers — re-run their playbooks (make ansible-<component>):")
            for name in sorted(stale):
                print(f"    - {name}  (consumes: {', '.join(sorted(stale[name]))})")
        print("  Hosts running the shared common role also re-read all.vars (make ansible-env).")

    with open(_STATE_FILE, "w") as f:
        json.dump(snapshot, f, indent=2, sort_keys=True)


# Consumed by the shared `common` role on every host — emitted into all.vars.
CORE_CONSUMES = {
    # Base URL of the apt caching proxy; "" (falsy) when no provider — the
    # common role then keeps upstream sources.
    "nexus_apt_proxy": {"capability": "apt.source", "optional": True, "default": ""},
    # Auth-log syslog forwarding target; absent when no log server exists.
    "common_log_server_address": {"capability": "syslog.target", "optional": True},
}
