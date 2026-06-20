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
INCLUDE_VMS=0
ARGS=()
for a in "$@"; do
    case "$a" in
        --keep-minio)  KEEP_MINIO=1 ;;
        --dry-run)     DRY_RUN=1 ;;
        --include-vms) INCLUDE_VMS=1 ;;
        *)             ARGS+=("$a") ;;
    esac
done
ENV="${ARGS[0]:-${ENV:-sandbox}}"
export ENV
# shellcheck source=lib.sh
source "${SELF_DIR}/lib.sh"
load_envrc
_pve_init

log "Teardown target pool: ${POOL_ID} (vmid range ${VMID_MIN}-${VMID_MAX})"
[[ "$KEEP_MINIO"   == 1 ]] && log "  --keep-minio: MinIO LXC will be preserved"
[[ "$DRY_RUN"      == 1 ]] && log "  --dry-run: no mutations will be performed"
# Clone-based VMs (e.g. root-ca, splunk) are created from templates. The earlier
# rationale here — "the sandbox token cannot clone them (Permission check
# failed)" — is DISPROVEN: an --include-vms cold rebuild's `terraform apply`
# recreates the root-CA VM from its template fine (verified). The real historical
# blocker was template storage/node-locality, not IAM permissions. VMs are still
# preserved by DEFAULT here as a conservative choice — a full --include-vms wipe
# also destroys the offline root CA, regenerating the entire trust chain, which
# is rarely what you want for a quick iteration. Pass --include-vms for a true
# cold start from nothing (now safe: the token can re-clone the templates).
[[ "$INCLUDE_VMS" == 0 ]] && log "  VMs (qemu) preserved by default (conservative — keeps the offline root CA); pass --include-vms for a full cold start"

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

# Print a guest's current status, or "gone" if the vmid no longer exists.
# (lxc and qemu live at different API paths — the caller passes $typ.)
guest_status() {
    local node="$1" typ="$2" vmid="$3" raw
    raw="$(pve_api GET "/nodes/${node}/${typ}/${vmid}/status/current" 2>/dev/null || echo '')"
    printf '%s' "$raw" | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["data"]["status"])
except Exception: print("gone")' 2>/dev/null || echo gone
}

# Wait for a guest's status to reach a target (or vanish), up to ~60s.
wait_status() {
    local node="$1" typ="$2" vmid="$3" want="$4" st
    for _ in $(seq 1 60); do
        st="$(guest_status "$node" "$typ" "$vmid")"
        [[ "$st" == "$want" || "$st" == "gone" ]] && return 0
        sleep 1
    done
    return 1
}

# Issue a purge-DELETE and confirm Proxmox actually ACCEPTED it (queued an async
# task) rather than transiently rejecting it. A DELETE fired right after vzstop
# released the config lock can come back HTTP 500 "can't lock file - got timeout";
# pve_api uses `curl -sS` (no --fail) so that error body returns as exit 0 and the
# guest is never purged — only the gone-poll later notices, after wasting the whole
# ceiling. A successful DELETE returns a task id ("UPID:..."); anything else is a
# rejection to retry. Observed 2026-06-20: a guest, then two guests, silently
# un-deleted before this retry guard was added.
delete_guest() {
    local node="$1" typ="$2" vmid="$3" name="$4" resp
    for attempt in 1 2 3 4 5; do
        resp="$(pve_api DELETE "/nodes/${node}/${typ}/${vmid}?purge=1&destroy-unreferenced-disks=1" 2>/dev/null || true)"
        printf '%s' "$resp" | grep -q 'UPID:' && return 0
        warn "DELETE for ${vmid} (${name}) not accepted (attempt ${attempt}/5): ${resp:-<empty>} — retrying in 3s"
        sleep 3
    done
    return 1
}

# vmids we actually issued a DELETE for, recorded as "vmid|typ|node|name" so the
# post-delete wait can poll the EXACT guests we removed (lxc + qemu both) until
# the async purge task has truly made each one disappear.
DELETED=()

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
    if [[ "$INCLUDE_VMS" == 0 && "$typ" == "qemu" ]]; then
        log "KEEP ${vmid} (${name}) — qemu VM, not token-rebuildable (use --include-vms to force)"
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
    delete_guest "$node" "$typ" "$vmid" "$name" \
        || die "DELETE not accepted for ${vmid} (${name}) after 5 attempts"
    DELETED+=("${vmid}|${typ}|${node}|${name}")
done

# --- wait for every deleted guest to be truly GONE ---------------------------
# The DELETE above only QUEUES an async purge task; the API returns before the
# guest is actually removed. If teardown declares "complete" while a purge is
# still in flight, the next loop phase (recreate-minio / run.sh) collides with
# "CT <vmid> already exists". So poll each deleted vmid — lxc and qemu both, at
# their respective API paths — until status/current reports "gone". Polling all
# at once lets the node's concurrent purges overlap instead of serialising a
# per-guest ceiling. A vmid still present at the ceiling is a real stuck purge:
# die loudly rather than continue into a guaranteed downstream collision.
if [[ "${#DELETED[@]}" -gt 0 ]]; then
    GONE_DEADLINE=$(( $(date +%s) + 180 ))   # ~3 min ceiling for all purges combined
    log "Waiting for ${#DELETED[@]} deleted guest(s) to be purged (gone)..."
    pending=("${DELETED[@]}")
    while [[ "${#pending[@]}" -gt 0 ]]; do
        still=()
        for d in "${pending[@]}"; do
            IFS='|' read -r vmid typ node name <<<"$d"
            st="$(guest_status "$node" "$typ" "$vmid")"
            if [[ "$st" == "gone" ]]; then
                log "  ${typ} ${vmid} (${name}) gone"
            else
                still+=("$d")
            fi
        done
        pending=("${still[@]}")
        [[ "${#pending[@]}" -eq 0 ]] && break
        if (( $(date +%s) >= GONE_DEADLINE )); then
            for d in "${pending[@]}"; do
                IFS='|' read -r vmid typ node name <<<"$d"
                warn "STUCK: ${typ} ${vmid} (${name}) still present after purge ceiling (status=$(guest_status "$node" "$typ" "$vmid"))"
            done
            die "purge did not complete for ${#pending[@]} guest(s) within 180s — refusing to declare teardown complete (downstream recreate would collide)"
        fi
        sleep 3
    done
fi

log "Teardown complete."
