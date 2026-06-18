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


def is_inside_container() -> bool:
    """Detect if we're running inside the dev container."""
    if os.path.exists("/.dockerenv"):
        return True
    proxy = os.environ.get("http_proxy", "") or os.environ.get("HTTP_PROXY", "")
    return "squid-proxy" in proxy
