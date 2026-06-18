#!/usr/bin/env bash
# =============================================================================
# collect-all.sh — Tier-2 driver: run every per-service collector and write each
# service's RAW state dump to a per-service file under a dump dir, plus echo to
# stdout. NO assertions, NO judgment — the /sanity-sweep skill drives an agent
# to read these dumps and judge.
#
# Usage:
#   bash scripts/collect/collect-all.sh [DUMP_DIR] [ENV]
#     DUMP_DIR default: .claude/session/collect-dump/<UTC-timestamp>/
#     ENV      default: sandbox
#
# Splunk (.17) is skipped when services.splunk.enabled is false (off by design
# in sandbox).
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

# Order mirrors the trust/dependency chain (CA -> repo -> resolver -> storage/telemetry).
COLLECTORS=(issuing-ca nexus dns-auth dnsdist log-server minio)

printf 'Tier-2 collect-all (ENV=%s) -> dump dir: %s\n' "$ENV" "$DUMP_DIR"

for svc in "${COLLECTORS[@]}"; do
    out="${DUMP_DIR}/${svc}.txt"
    printf '\n>>> collect-%s  (-> %s)\n' "$svc" "$out"
    # tee raw dump to both stdout and the per-service file.
    bash "${SELF_DIR}/collect-${svc}.sh" 2>&1 | tee "$out"
done

# Splunk — only when enabled.
splunk_enabled="$(cfg services.splunk.enabled)"
if [[ "$splunk_enabled" == "True" && -f "${SELF_DIR}/collect-splunk.sh" ]]; then
    out="${DUMP_DIR}/splunk.txt"
    printf '\n>>> collect-splunk  (-> %s)\n' "$out"
    bash "${SELF_DIR}/collect-splunk.sh" 2>&1 | tee "$out"
else
    printf '\n>>> collect-splunk: SKIP (services.splunk.enabled=%s — off by design in sandbox)\n' "${splunk_enabled:-false}"
fi

printf '\n=== collect-all complete. Raw dumps in: %s ===\n' "$DUMP_DIR"
printf 'Next: the /sanity-sweep skill drives an agent to read these and judge.\n'
