"""genconfig.discovery — find and load component manifests.

Components live in `components/<name>/component.yml` (public, committed) and
`components.local/<name>/component.yml` (gitignored overlay for private
components). Both trees are discovered through this single code path; a name
collision between the two is a HARD error, never a silent shadow.

Manifest shape (v1 — see docs/design/component-architecture.md §4):

  name: <component>
  description: <one-liner>
  order: <int>                # deploy/emission ordering (default 100, ties by name)
  instances:
    <instance>:
      kind: vm | lxc | none   # none = out-of-TF-graph (e.g. the state backend)
      tf_key: <key>           # services-map/state key. Default: component name for
                              # single-instance components, <component>_<instance>
                              # for multi-instance ones.
      group: <group>          # ansible inventory group. Default: tf_key.
      resources: {cores, memory_mb, disk_gb, swap_mb}
      options:   {started, start_on_boot, agent_enabled, cpu_type, os_type,
                  nesting, unprivileged, data_disk_size, data_disk_path}
      config:
        required: [<field>, ...]   # validated only when the component is enabled
        optional: [<field>, ...]
        defaults: {<field>: <value>, ...}
  ansible:
    playbook: <path relative to the component dir>
  env:                        # .envrc contributions
    header: <section comment>
    vars:
      - {name: <VAR>, comment: <inline comment>}
  bootstrap: <script>         # kind:none only — out-of-band provisioning entrypoint
  seam: [...]                 # declared extension surfaces (phase 4)
  placeholder: CHANGE_ME      # sentinel contract (core default)
"""

import os
import sys

import yaml

from .config import REPO_ROOT

PUBLIC_COMPONENTS_DIR = os.path.join(REPO_ROOT, "components")
LOCAL_COMPONENTS_DIR = os.path.join(REPO_ROOT, "components.local")

_VALID_KINDS = {"vm", "lxc", "none"}


def _load_tree(root: str, source: str) -> dict:
    found = {}
    if not os.path.isdir(root):
        return found
    for entry in sorted(os.listdir(root)):
        cdir = os.path.join(root, entry)
        manifest_path = os.path.join(cdir, "component.yml")
        if not os.path.isdir(cdir) or not os.path.isfile(manifest_path):
            continue
        with open(manifest_path) as f:
            try:
                manifest = yaml.safe_load(f) or {}
            except yaml.YAMLError as e:
                sys.exit(f"Component error: cannot parse {manifest_path}: {e}")
        name = manifest.get("name")
        if not name:
            sys.exit(f"Component error: {manifest_path} is missing 'name:'.")
        if name != entry:
            sys.exit(
                f"Component error: {manifest_path} declares name '{name}' but lives in "
                f"directory '{entry}' — they must match."
            )
        _validate_manifest(manifest, manifest_path)
        found[name] = {"manifest": manifest, "dir": cdir, "source": source}
    return found


def _validate_manifest(manifest: dict, path: str) -> None:
    instances = manifest.get("instances")
    if not instances or not isinstance(instances, dict):
        sys.exit(f"Component error: {path} needs a non-empty 'instances:' map.")
    for iname, inst in instances.items():
        if not isinstance(inst, dict):
            sys.exit(f"Component error: {path} instance '{iname}' must be a map.")
        kind = inst.get("kind")
        if kind not in _VALID_KINDS:
            sys.exit(
                f"Component error: {path} instance '{iname}' has kind '{kind}' — "
                f"must be one of {sorted(_VALID_KINDS)}."
            )
    if any(i.get("kind") == "none" for i in instances.values()) and len(instances) > 1:
        sys.exit(f"Component error: {path}: kind 'none' components must be single-instance.")


def instance_tf_key(component_name: str, instance_name: str, inst: dict, single: bool) -> str:
    """State-address key in the Terraform services map (stable across refactors)."""
    if inst.get("tf_key"):
        return inst["tf_key"]
    return component_name if single else f"{component_name}_{instance_name}"


def instance_group(component_name: str, instance_name: str, inst: dict, single: bool) -> str:
    """Ansible inventory group for the instance's host."""
    return inst.get("group") or instance_tf_key(component_name, instance_name, inst, single)


def discover_components() -> dict:
    """Return {name: {manifest, dir, source}} for all components, both trees.

    A component present in both trees is a hard error; tf_key collisions across
    components are a hard error too.
    """
    public = _load_tree(PUBLIC_COMPONENTS_DIR, "public")
    local = _load_tree(LOCAL_COMPONENTS_DIR, "local")

    collisions = sorted(set(public) & set(local))
    if collisions:
        sys.exit(
            "Component error: name collision between components/ and components.local/: "
            f"{', '.join(collisions)}. Rename the private component — shadowing a public "
            "one is not supported."
        )

    merged = {**public, **local}

    seen_tf_keys: dict[str, str] = {}
    for name, comp in merged.items():
        instances = comp["manifest"]["instances"]
        single = len(instances) == 1
        for iname, inst in instances.items():
            key = instance_tf_key(name, iname, inst, single)
            if key in seen_tf_keys:
                sys.exit(
                    f"Component error: tf_key '{key}' is claimed by both "
                    f"'{seen_tf_keys[key]}' and '{name}'."
                )
            seen_tf_keys[key] = name
    return merged


def enabled_components(components: dict, cfg: dict) -> dict:
    """Subset of discovered components enabled in this environment's config.

    A component is enabled when config has services.<name> with enabled: true.
    """
    svcs = cfg.get("services", {}) or {}
    out = {}
    for name, comp in components.items():
        svc = svcs.get(name)
        if isinstance(svc, dict) and bool(svc.get("enabled", False)):
            out[name] = comp
    return out


def component_order(comp: dict) -> tuple:
    return (comp["manifest"].get("order", 100), comp["manifest"]["name"])


def instance_config(cfg: dict, comp: dict, instance_name: str) -> dict:
    """The merged config block for one instance: env config over manifest defaults.

    Single-instance components read services.<component> directly; multi-instance
    ones read services.<component>.<instance>.
    """
    manifest = comp["manifest"]
    instances = manifest["instances"]
    svc = (cfg.get("services", {}) or {}).get(manifest["name"], {}) or {}
    blk = svc if len(instances) == 1 else (svc.get(instance_name) or {})
    defaults = ((instances[instance_name].get("config") or {}).get("defaults") or {})
    merged = dict(defaults)
    merged.update(blk if isinstance(blk, dict) else {})
    return merged
