"""genconfig.emit.config_example — assemble config/<env>.yml.example files.

The committed example configs are ASSEMBLED, never hand-edited as a whole:
  config/example-core/<env>.yml.in       env skeleton (infra, terraform, agent)
  components/*/config.example.yml.in     one service fragment per component
  + a generated services: header and hosts: tail.

This keeps examples from going stale against the component set and keeps
private component shapes out of the public examples (components.local/ is
deliberately NOT included). Fragments may use @DOMAIN@ and @NETWORK@, replaced
from the core skeleton's domain_name and its `#@ network:` directive.
"""

import os
import re
import sys

from ..config import REPO_ROOT
from ..discovery import component_order, discover_components

_SERVICES_HEADER = """\
# Services deployed to the homelab — one block per component. Each block's
# shape is declared by components/<name>/component.yml; `make configure`
# derives the Ansible inventory group and endpoint wiring from it.
# This file is ASSEMBLED by `make examples` — edit the component fragment
# (components/<name>/config.example.yml.in) or the core skeleton
# (config/example-core/<env>.yml.in), not this file.
services:
"""

_HOSTS_TAIL = """\
# Ad-hoc hosts not covered by a named service above.
# Each top-level key is an Ansible group; hosts within are inventory entries.
hosts:
  {env}:
    # example-vm-01:
    #   ansible_host: 192.168.X.X
    #   ansible_user: ubuntu
"""


def gen_config_example(env: str, components: dict | None = None) -> str:
    core_path = os.path.join(REPO_ROOT, "config", "example-core", f"{env}.yml.in")
    if not os.path.isfile(core_path):
        sys.exit(f"ERROR: {core_path} not found — cannot assemble config/{env}.yml.example.")
    with open(core_path) as f:
        core_raw = f.read()

    network = ""
    core_lines = []
    for line in core_raw.splitlines():
        m = re.match(r"^#@\s*network:\s*(\S+)", line)
        if m:
            network = m.group(1)
            continue
        if line.startswith("#@"):
            continue
        core_lines.append(line)
    dm = re.search(r'^domain_name:\s*"?([A-Za-z0-9.-]+)"?', core_raw, re.M)
    domain = dm.group(1) if dm else "example.com"

    components = components or discover_components()
    fragments = []
    for comp in sorted(components.values(), key=component_order):
        if comp["source"] != "public":
            continue  # private shapes never leak into committed examples
        frag_path = os.path.join(comp["dir"], "config.example.yml.in")
        if not os.path.isfile(frag_path):
            continue
        with open(frag_path) as f:
            frag = f.read().rstrip("\n")
        frag = frag.replace("@DOMAIN@", domain).replace("@NETWORK@", network)
        fragments.append(frag)

    core = "\n".join(core_lines).strip("\n")
    return (
        core + "\n\n" + _SERVICES_HEADER
        + "\n\n".join(fragments) + "\n\n"
        + _HOSTS_TAIL.format(env=env)
    )
