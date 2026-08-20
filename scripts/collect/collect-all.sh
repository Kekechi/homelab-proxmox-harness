#!/usr/bin/env bash
# =============================================================================
# collect-all.sh — Tier-2 driver: run every enabled component's collect.sh and
# write each component's RAW state dump to a per-component file under a dump
# dir, plus echo to stdout. NO assertions, NO judgment — the /sanity-sweep
# skill drives an agent to read these dumps and judge.
#
# Components are DISCOVERED (components/ + components.local/, manifest order),
# never hand-listed. A component is skipped when services.<name>.enabled is
# not true or when it has no collect.sh.
#
# Usage:
#   bash scripts/collect/collect-all.sh [DUMP_DIR] [ENV]
#     DUMP_DIR default: .claude/session/collect-dump/<UTC-timestamp>/
#     ENV      default: sandbox
#
# NEXUS_ADMIN_PASSWORD (env, optional) enriches the nexus dump with privileged
# sections (roles/privileges/users); without it those sections note the gap.
# =============================================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
export ENV="${2:-${ENV:-sandbox}}"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
DUMP_DIR="${1:-${REPO_ROOT}/.claude/session/collect-dump/${TS}}"
mkdir -p "$DUMP_DIR"
export COLLECT_DUMP_DIR="$DUMP_DIR"

# shellcheck source=lib.sh
source "${SELF_DIR}/lib.sh"

mapfile -t COMPONENT_DIRS < <(
    python3 - "$REPO_ROOT" <<'PYEOF'
import os, sys, yaml
root = sys.argv[1]
rows = []
for tree in ("components", "components.local"):
    base = os.path.join(root, tree)
    if not os.path.isdir(base):
        continue
    for entry in sorted(os.listdir(base)):
        manifest = os.path.join(base, entry, "component.yml")
        if os.path.isfile(manifest):
            with open(manifest) as f:
                m = yaml.safe_load(f) or {}
            rows.append((m.get("order", 100), m.get("name", entry), os.path.join(base, entry)))
for _, _, path in sorted(rows):
    print(path)
PYEOF
)

printf 'Tier-2 collect-all (ENV=%s) -> dump dir: %s\n' "$ENV" "$DUMP_DIR"

for cdir in "${COMPONENT_DIRS[@]}"; do
    name="$(basename "$cdir")"
    enabled="$(cfg "services.${name}.enabled")"
    if [[ "$enabled" != "True" && "$enabled" != "true" ]]; then
        printf '\n>>> collect-%s: SKIP (services.%s.enabled is not true — off by design)\n' "$name" "$name"
        continue
    fi
    if [[ ! -f "${cdir}/collect.sh" ]]; then
        printf '\n>>> collect-%s: SKIP (enabled but no collect.sh in %s)\n' "$name" "$cdir"
        continue
    fi
    out="${DUMP_DIR}/${name}.txt"
    printf '\n>>> collect-%s  (-> %s)\n' "$name" "$out"
    # tee raw dump to both stdout and the per-component file.
    bash "${cdir}/collect.sh" 2>&1 | tee "$out"
done

printf '\n=== collect-all complete. Raw dumps in: %s ===\n' "$DUMP_DIR"
printf 'Next: the /sanity-sweep skill drives an agent to read these and judge.\n'
