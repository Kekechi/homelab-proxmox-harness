#!/usr/bin/env bash
# =============================================================================
# verify-all.sh — Tier-1 machine gate: run every enabled component's verify.sh
# and aggregate to a single hard exit 0 (all green) / 1 (any component failed).
#
# Components are DISCOVERED, never hand-listed: components/*/verify.sh and
# components.local/*/verify.sh (private overlay) run in manifest `order:`.
# A component is skipped when config services.<name>.enabled is not true, or
# when it has no verify.sh (reported, so a silent gap is visible).
#
# Usage: bash scripts/verify/verify-all.sh [ENV]   (default ENV=sandbox)
# =============================================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ENV="${1:-${ENV:-sandbox}}"
# shellcheck source=lib.sh
source "${SELF_DIR}/lib.sh" "all"

# Discover components in manifest order (order:, ties by name), both trees.
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

overall=0
declare -a results=()

for cdir in "${COMPONENT_DIRS[@]}"; do
    name="$(basename "$cdir")"
    enabled="$(cfg "services.${name}.enabled")"
    printf '\n'
    if [[ "$enabled" != "True" && "$enabled" != "true" ]]; then
        printf '%s== verify-%s: SKIP (services.%s.enabled is not true — off by design) ==%s\n' \
            "$_c_yel" "$name" "$name" "$_c_rst"
        results+=("SKIP  verify-${name} (disabled)")
        continue
    fi
    if [[ ! -f "${cdir}/verify.sh" ]]; then
        printf '%s== verify-%s: SKIP (enabled but no verify.sh in %s) ==%s\n' \
            "$_c_yel" "$name" "$cdir" "$_c_rst"
        results+=("SKIP  verify-${name} (enabled, no verify.sh)")
        continue
    fi
    if bash "${cdir}/verify.sh"; then
        results+=("PASS  verify-${name}")
    else
        results+=("FAIL  verify-${name}")
        overall=1
    fi
done

# --- aggregate summary -------------------------------------------------------
printf '\n%s================ verify-all summary (ENV=%s) ================%s\n' "$_c_cyn" "$ENV" "$_c_rst"
for r in "${results[@]}"; do
    case "$r" in
        PASS*) printf '  %s%s%s\n' "$_c_grn" "$r" "$_c_rst" ;;
        FAIL*) printf '  %s%s%s\n' "$_c_red" "$r" "$_c_rst" ;;
        *)     printf '  %s%s%s\n' "$_c_yel" "$r" "$_c_rst" ;;
    esac
done

if [[ "$overall" -eq 0 ]]; then
    printf '%s================ verify-all: GREEN ================%s\n' "$_c_grn" "$_c_rst"
else
    printf '%s================ verify-all: RED ================%s\n' "$_c_red" "$_c_rst"
fi
exit "$overall"
