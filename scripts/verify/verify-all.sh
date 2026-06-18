#!/usr/bin/env bash
# =============================================================================
# verify-all.sh — Tier-1 machine gate: run every per-service verify and
# aggregate to a single hard exit 0 (all green) / 1 (any service failed).
#
# This is the cheap gate intended to run on every rebuild loop (WS2). It is
# behavioral: each verify-<svc>.sh queries the running daemon, not its config.
#
# Splunk is skipped gracefully when services.splunk.enabled is false in
# config/<env>.yml (it is OFF by design in sandbox).
#
# Usage: bash scripts/verify/verify-all.sh [ENV]   (default ENV=sandbox)
# =============================================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ENV="${1:-${ENV:-sandbox}}"
# shellcheck source=lib.sh
source "${SELF_DIR}/lib.sh" "all"

# Service -> script. Order follows the trust/dependency chain: CA, then the
# repo, then the resolver chain, then storage + telemetry.
SERVICES=(issuing-ca nexus dns-auth dnsdist dns-collector minio log-server)

overall=0
declare -a results=()

run_one() {
    local svc="$1"
    printf '\n'
    if bash "${SELF_DIR}/verify-${svc}.sh"; then
        results+=("PASS  verify-${svc}")
    else
        results+=("FAIL  verify-${svc}")
        overall=1
    fi
}

for svc in "${SERVICES[@]}"; do
    run_one "$svc"
done

# Splunk — only when enabled. OFF by design in sandbox.
printf '\n'
splunk_enabled="$(cfg services.splunk.enabled)"
if [[ "$splunk_enabled" == "True" ]]; then
    if [[ -f "${SELF_DIR}/verify-splunk.sh" ]]; then
        run_one "splunk"
    else
        printf '  %s[SKIP]%s verify-splunk: enabled but no verify-splunk.sh present\n' "$_c_yel" "$_c_rst"
        results+=("SKIP  verify-splunk (enabled, no script)")
    fi
else
    printf '%s== verify-splunk: SKIP (services.splunk.enabled=false — off by design) ==%s\n' "$_c_yel" "$_c_rst"
    results+=("SKIP  verify-splunk (disabled)")
fi

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
