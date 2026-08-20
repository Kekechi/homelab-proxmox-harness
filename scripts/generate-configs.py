#!/usr/bin/env python3
"""
generate-configs.py — Generate environment config files from config/<env>.yml

Thin shim. The implementation lives in the `genconfig/` package (split per the
decided per-output-artifact boundary — see scripts/genconfig/CLAUDE.md). This
file preserves the original CLI/entry behaviour exactly so `make configure`,
test-golden.py, and test-generator.py keep working unchanged.

Reads config/<env>.yml and generates:
  - terraform/<env>.tfvars
  - ansible/inventory/hosts.yml
  - ansible/ansible.cfg (agent-host facts from the config agent: section)
  - .envrc (non-secret portion, with CHANGE_ME placeholders for secrets)
  - .env.mk (Makefile-includable variables)
  - ansible/inventory/group_vars/pki_*/vars.yml

Usage:
  python3 scripts/generate-configs.py [sandbox|production] [--force]

Options:
  --force   Overwrite .envrc even if it contains non-placeholder secrets
"""

import os
import sys

# Ensure the genconfig package is importable whether this file is run as a
# script (scripts/ already on sys.path[0]) or loaded by path via
# importlib.spec_from_file_location (test harnesses — sys.path is untouched).
_SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

# Re-export the full public surface so callers that load this module by path
# (gen.gen_tfvars, gen.validate_schema, gen.CHANGE_ME, ...) keep working.
from genconfig.main import *  # noqa: F401,F403,E402
from genconfig.main import main  # noqa: E402


if __name__ == "__main__":
    main()
