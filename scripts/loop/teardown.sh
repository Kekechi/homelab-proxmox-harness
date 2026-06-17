#!/usr/bin/env bash
# =============================================================================
# teardown.sh — API sweep of the sandbox pool (the loop's destroy step)
#
# Deletes every guest that is a member of terraform.pool_id, scoped to that
# pool ONLY. Simpler than `terraform destroy` and it sidesteps the bootstrap
# paradox (TF state lives in the MinIO box this sweep also removes).
#
# Usage:
#   bash scripts/loop/teardown.sh [ENV] [--keep-minio] [--dry-run]
#
#   --keep-minio  leave the MinIO LXC (name matches *minio*) running, for faster
#                 iteration when MinIO/state are not under test. Default: full wipe.
#   --dry-run     print what would be deleted; mutate nothing.
#
# Safety:
#   - Strictly filters by pool == terraform.pool_id (templates-pool untouched).
#   - Refuses to act on any vmid outside [VMID_MIN, VMID_MAX] or >= 9000.
# =============================================================================
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEEP_MINIO=0
DRY_RUN=0
ARGS=()
for a in "$@"; do
    case "$a" in
        --keep-minio) KEEP_MINIO=1 ;;
        --dry-run)    DRY_RUN=1 ;;
        *)            ARGS+=("$a") ;;
    esac
done
ENV="${ARGS[0]:-${ENV:-sandbox}}"
export ENV
# shellcheck source=lib.sh
source "${SELF_DIR}/lib.sh"
load_envrc
_pve_init

log "Teardown target pool: ${POOL_ID} (vmid range ${VMID_MIN}-${VMID_MAX})"
[[ "$KEEP_MINIO" == 1 ]] && log "  --keep-minio: MinIO LXC will be preserved"
[[ "$DRY_RUN"   == 1 ]] && log "  --dry-run: no mutations will be performed"

# Enumerate cluster guests and select pool members as: vmid|type|node|status|name
# (JSON goes through a temp file so the heredoc program and the API data don't
#  both contend for stdin.)
RESOURCES_JSON="$(mktemp)"
trap 'rm -f "$RESOURCES_JSON"' EXIT
pve_api GET "/cluster/resources?type=vm" > "$RESOURCES_JSON"
mapfile -t MEMBERS < <(
    python3 - "$POOL_ID" "$RESOURCES_JSON" <<'PY'
import sys, json
pool = sys.argv[1]
with open(sys.argv[2]) as f:
    data = json.load(f).get("data", [])
for r in data:
    if r.get("pool") == pool:
        vmid = r.get("vmid"); typ = r.get("type")  # qemu|lxc
        node = r.get("node"); status = r.get("status"); name = r.get("name", "")
        print(f"{vmid}|{typ}|{node}|{status}|{name}")
PY
)

if [[ "${#MEMBERS[@]}" -eq 0 ]]; then
    log "Pool ${POOL_ID} has no members — nothing to tear down."
    exit 0
fi

log "Found ${#MEMBERS[@]} pool member(s):"
printf '    %s\n' "${MEMBERS[@]}" >&2

# Wait for a guest's status to reach a target (or vanish), up to ~60s.
wait_status() {
    local node="$1" typ="$2" vmid="$3" want="$4" raw st
    for _ in $(seq 1 60); do
        raw="$(pve_api GET "/nodes/${node}/${typ}/${vmid}/status/current" 2>/dev/null || echo '')"
        st="$(printf '%s' "$raw" | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["data"]["status"])
except Exception: print("gone")' 2>/dev/null || echo gone)"
        [[ "$st" == "$want" || "$st" == "gone" ]] && return 0
        sleep 1
    done
    return 1
}

for line in "${MEMBERS[@]}"; do
    IFS='|' read -r vmid typ node status name <<<"$line"

    # --- safety asserts ---
    if (( vmid < VMID_MIN || vmid > VMID_MAX )); then
        warn "SKIP ${vmid} (${name}) — outside sandbox vmid range ${VMID_MIN}-${VMID_MAX}"
        continue
    fi
    if (( vmid >= 9000 )); then
        warn "SKIP ${vmid} (${name}) — template range, never deleted"
        continue
    fi
    if [[ "$KEEP_MINIO" == 1 && "$name" == *minio* ]]; then
        log "KEEP ${vmid} (${name}) — --keep-minio"
        continue
    fi

    if [[ "$DRY_RUN" == 1 ]]; then
        log "DRY-RUN would delete ${typ} ${vmid} (${name}) on ${node} [status=${status}]"
        continue
    fi

    if [[ "$status" == "running" ]]; then
        log "Stopping ${typ} ${vmid} (${name})..."
        pve_api POST "/nodes/${node}/${typ}/${vmid}/status/stop" >/dev/null || \
            warn "stop call failed for ${vmid} (continuing)"
        wait_status "$node" "$typ" "$vmid" stopped || warn "${vmid} did not report stopped in time"
    fi

    log "Deleting ${typ} ${vmid} (${name})..."
    pve_api DELETE "/nodes/${node}/${typ}/${vmid}?purge=1&destroy-unreferenced-disks=1" >/dev/null \
        || die "DELETE failed for ${vmid} (${name})"
    wait_status "$node" "$typ" "$vmid" gone || warn "${vmid} still present after delete (purge task may be async)"
done

log "Teardown complete."
