"""genconfig.main — CLI entry point + public symbol surface.

generate-configs.py is a thin shim that does `from genconfig.main import *`,
so every name re-exported here is also reachable as an attribute of the loaded
generate-configs.py module. The test harnesses (test-golden.py, test-generator.py)
load that module by path and call e.g. gen.gen_tfvars / gen.validate_schema —
keep this surface stable.
"""

import os
import re
import sys

# Public surface re-exported for the shim and the test harnesses.
from .config import CHANGE_ME, REPO_ROOT, is_inside_container, load_config
from .discovery import (
    component_order,
    discover_components,
    enabled_components,
    instance_config,
    instance_group,
    instance_tf_key,
)
from .helpers import (
    _envrc_secret_vars,
    _derive_dns_records,
    _hcl_str,
    _strip_prefix,
    atomic_write,
    resolve_network,
    validate_cidr,
    validate_domain_name,
    write_file,
)
from .validation import (
    _NEXUS_REQUIRED_APT_REPOS,
    validate_nexus_apt_proxy_repos,
    validate_nexus_raw_hosted_repos,
    validate_schema,
)
from .emit.env_mk import gen_env_mk
from .emit.envrc import gen_envrc
from .emit.inventory import gen_inventory
from .emit.pki_group_vars import gen_pki_group_vars
from .emit.tfvars import gen_tfvars

__all__ = [
    "component_order",
    "discover_components",
    "enabled_components",
    "instance_config",
    "instance_group",
    "instance_tf_key",
    "CHANGE_ME",
    "REPO_ROOT",
    "is_inside_container",
    "load_config",
    "_envrc_secret_vars",
    "_derive_dns_records",
    "_hcl_str",
    "_strip_prefix",
    "atomic_write",
    "resolve_network",
    "validate_cidr",
    "validate_domain_name",
    "write_file",
    "_NEXUS_REQUIRED_APT_REPOS",
    "validate_nexus_apt_proxy_repos",
    "validate_nexus_raw_hosted_repos",
    "validate_schema",
    "gen_env_mk",
    "gen_envrc",
    "gen_inventory",
    "gen_pki_group_vars",
    "gen_tfvars",
    "main",
]


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
