"""genconfig.config — config loading, repo paths, and environment detection."""

import os
import sys

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is required. Install with: pip install pyyaml", file=sys.stderr)
    sys.exit(1)

# REPO_ROOT: scripts/genconfig/config.py → repo root is three levels up.
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CHANGE_ME = "CHANGE_ME"


def _deep_merge(base: dict, overlay: dict) -> dict:
    """Recursive dict merge — overlay wins; nested dicts merge, everything else
    (lists included) is replaced wholesale."""
    out = dict(base)
    for k, v in overlay.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def load_config(env: str) -> dict:
    path = os.path.join(REPO_ROOT, "config", f"{env}.yml")
    if not os.path.exists(path):
        example = f"config/{env}.yml.example"
        print(f"ERROR: config/{env}.yml not found.", file=sys.stderr)
        print(f"       Copy the example and fill in your values:", file=sys.stderr)
        print(f"       cp {example} config/{env}.yml", file=sys.stderr)
        sys.exit(1)
    with open(path) as f:
        cfg = yaml.safe_load(f)

    # Private overlay: config/<env>.local.yml (gitignored) deep-merges over the
    # base config — instance values for components.local/ components, or local
    # overrides of public values. Same discovery/emission path from here on.
    local_path = os.path.join(REPO_ROOT, "config", f"{env}.local.yml")
    if os.path.exists(local_path):
        with open(local_path) as f:
            local = yaml.safe_load(f) or {}
        if not isinstance(local, dict):
            print(f"ERROR: config/{env}.local.yml must be a mapping.", file=sys.stderr)
            sys.exit(1)
        cfg = _deep_merge(cfg, local)
        print(f"  (merged config/{env}.local.yml overlay)")
    return cfg


