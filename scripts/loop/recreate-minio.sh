#!/usr/bin/env bash
# =============================================================================
# recreate-minio.sh — create the MinIO LXC via the Proxmox API + cloud-init
#
# Replaces the legacy GUI / `pct exec` procedure. MinIO is outside the Terraform
# graph (it holds the TF state bucket — bootstrap paradox), so it is recreated
# with a direct API call and SSH-key injection, then provisioned by Ansible.
#
# Usage:
#   bash scripts/loop/recreate-minio.sh [ENV] [--vmid N] [--no-wait]
#     --vmid N    override the LXC id (default: terraform.vm_id_range_start).
#                 Use a scratch id (e.g. 1099) to smoke-test create capability.
#     --no-wait   don't block on SSH readiness after start.
#
# Mirrors the deployed spec: unprivileged, nesting=1, 8G rootfs, bridge from
# infrastructure.networks. SSH key comes from config ssh.public_key.
# =============================================================================
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VMID_OVERRIDE=""
IP_OVERRIDE=""
WAIT_SSH=1
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmid)    VMID_OVERRIDE="$2"; shift 2 ;;
        --ip)      IP_OVERRIDE="$2"; shift 2 ;;
        --no-wait) WAIT_SSH=0; shift ;;
        *)         ARGS+=("$1"); shift ;;
    esac
done
ENV="${ARGS[0]:-${ENV:-sandbox}}"
export ENV
# shellcheck source=lib.sh
source "${SELF_DIR}/lib.sh"
load_envrc
_pve_init

# --- resolve spec from config ------------------------------------------------
NODE="$(cfg services.minio.node)"
IP="$(cfg services.minio.ip)"
HOSTNAME="$(cfg services.minio.hostname)"
MAC="$(cfg services.minio.mac)"          # optional: pin the LXC MAC (see NET0 note below)
NET_NAME="$(cfg services.minio.network)"; : "${NET_NAME:=$(cfg infrastructure.default_network)}"
BRIDGE="$(cfg "infrastructure.networks.${NET_NAME}.bridge")"
GATEWAY="$(cfg "infrastructure.networks.${NET_NAME}.gateway")"
CIDR="$(cfg "infrastructure.networks.${NET_NAME}.cidr")"
PREFIX="${CIDR##*/}"; : "${PREFIX:=24}"
TEMPLATE="$(cfg infrastructure.storage.lxc_template_file_id)"
DATASTORE="$(cfg infrastructure.storage.datastore_id)"
SSH_KEY="$(cfg ssh.public_key)"
# Bootstrap resolver: use the configured dns_server (a public resolver during a
# cold start, since internal dnsdist is down). Fall back to the gateway.
NAMESERVER="$(cfg infrastructure.dns_server)"; : "${NAMESERVER:=$GATEWAY}"
VMID="${VMID_OVERRIDE:-$(cfg terraform.vm_id_range_start)}"
[[ -n "$IP_OVERRIDE" ]] && IP="$IP_OVERRIDE"

[[ -n "$NODE" && -n "$IP" && -n "$BRIDGE" && -n "$GATEWAY" && -n "$TEMPLATE" && -n "$DATASTORE" && -n "$SSH_KEY" ]] \
    || die "incomplete MinIO spec from config/${ENV}.yml (node=$NODE ip=$IP bridge=$BRIDGE gw=$GATEWAY template=$TEMPLATE ds=$DATASTORE)"

log "Recreating MinIO LXC: vmid=${VMID} host=${HOSTNAME} node=${NODE} ip=${IP}/${PREFIX} bridge=${BRIDGE}"

# Pin the MAC when config provides one. The loop reuses MinIO's fixed IP on every
# recreate but Proxmox otherwise assigns a FRESH random MAC each time — so the
# upstream L3 gateway keeps a now-dead IP->old-MAC ARP entry and blackholes the
# path until that entry ages out (~16-20 min). Confirmed 2026-06-20 via the
# gateway's own ARP log showing the entry move at the exact second the path
# recovered. Reusing a stable MAC keeps the gateway's ARP entry valid across
# recreate → no blackhole.
NET0="name=eth0,bridge=${BRIDGE},firewall=1,gw=${GATEWAY},ip=${IP}/${PREFIX},type=veth"
[[ -n "$MAC" ]] && NET0="${NET0},hwaddr=${MAC}"

# --- create ------------------------------------------------------------------
# Try with pool assignment first (matches the rest of the sandbox pool). If the
# token lacks Pool.Allocate, retry without it (the loop still finds the box by
# vmid, and a warning is emitted).
create() {
    local with_pool="$1" resp
    local -a fields=(
        --data-urlencode "vmid=${VMID}"
        --data-urlencode "hostname=${HOSTNAME}"
        --data-urlencode "ostemplate=${TEMPLATE}"
        --data-urlencode "storage=${DATASTORE}"
        --data-urlencode "rootfs=${DATASTORE}:8"
        --data-urlencode "cores=1"
        --data-urlencode "memory=512"
        --data-urlencode "swap=512"
        --data-urlencode "unprivileged=1"
        --data-urlencode "features=nesting=1"
        --data-urlencode "net0=${NET0}"
        --data-urlencode "nameserver=${NAMESERVER}"
        --data-urlencode "ssh-public-keys=${SSH_KEY}"
        --data-urlencode "start=1"
        --data-urlencode "onboot=1"
    )
    [[ "$with_pool" == 1 ]] && fields+=( --data-urlencode "pool=${POOL_ID}" )
    resp="$(pve_api POST "/nodes/${NODE}/lxc" "${fields[@]}")"
    printf '%s' "$resp"
}

log "Submitting create (with pool=${POOL_ID})..."
RESP="$(create 1 || true)"
if printf '%s' "$RESP" | grep -qiE 'Pool\.Allocate|/pool/.*permission|403'; then
    warn "pool assignment denied by token — retrying create WITHOUT pool (box will not be a pool member)"
    RESP="$(create 0)"
fi

UPID="$(printf '%s' "$RESP" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("data") or "")
except Exception: print("")' 2>/dev/null || echo "")"
if [[ -z "$UPID" ]]; then
    die "create returned no task id. Raw response: ${RESP}"
fi
log "Create task: ${UPID}"

# --- wait for the create/start task to finish --------------------------------
wait_task() {
    local node="$1" upid="$2" raw st
    for _ in $(seq 1 180); do
        raw="$(pve_api GET "/nodes/${node}/tasks/${upid}/status" 2>/dev/null || echo '')"
        st="$(printf '%s' "$raw" | python3 -c 'import sys,json
try:
 d=json.load(sys.stdin)["data"]; print(d.get("status",""), d.get("exitstatus",""))
except Exception: print("")' 2>/dev/null || echo "")"
        case "$st" in
            "stopped OK") return 0 ;;
            stopped*)     warn "task ended: ${st}"; return 1 ;;
        esac
        sleep 2
    done
    return 1
}
wait_task "$NODE" "$UPID" || die "create task did not complete OK"
log "MinIO LXC created and started."

# --- wait for SSH ------------------------------------------------------------
# Layered readiness probe (WS2). A freshly created LXC's network path (observed
# under the retired proxy setup) is INTERMITTENTLY LOSSY while it settles (SYN dropped early, then full SSH
# KEX stalls while a 1-RTT banner grab can still squeak through). ROOT CAUSE
# (CONFIRMED 2026-06-20, supersedes the earlier fwbr-settling guess): the loop
# reuses MinIO's fixed IP but Proxmox assigns a fresh random MAC each recreate, so
# the L3 gateway keeps a dead IP->old-MAC ARP entry and blackholes the path until
# that entry ages out (~16-20 min). Proven by the gateway's own ARP log showing the
# entry move to the new MAC at the same second the path recovered. It is NOT local
# fwbr settling (that is seconds, not minutes) and was wrongly attributed to it when
# no upstream/node visibility was available. The fix is to pin a stable MAC
# (services.minio.mac → hwaddr above) so the gateway's ARP entry stays valid. This
# probe remains as defense-in-depth: it must survive any residual lossy window
# without false-readying and without dying mid-settle.
#
# Two consequences for the probe:
#   1. The readiness signal is NEITHER "TCP :22 open" NOR a single SSH success —
#      both can pass mid-settle while the next real connection still stalls. We
#      require N CONSECUTIVE full SSH handshakes (multi-RTT KEX+auth) so one lucky
#      success in the lossy window cannot declare a false "ready".
#   2. The deadline is a SAFETY NET, not the readiness mechanism: readiness is
#      declared by the signal above; the clock only bounds a genuinely stuck box.
#      It is set above the observed ~19.5 min settle so it never races a healthy
#      first boot (the old blind 720 s cap died mid-settle — that was the flake).
# Every failed poll logs WHICH layer is the blocker (TCP CONNECT vs full
# handshake) so a future halt names what is lagging instead of dying blind.
if [[ "$WAIT_SSH" == 1 ]]; then
    SSH_USER="$(cfg services.minio.ansible_user)"; : "${SSH_USER:=root}"
    READY_NEED=3                                 # consecutive full SSH handshakes to declare ready
    PROBE_T0="$(date +%s)"
    DEADLINE=$(( PROBE_T0 + 1500 ))              # 25 min safety net (> observed ~19.5 min settle)
    log "Waiting for SSH on ${IP}:22 — need ${READY_NEED} consecutive full handshakes..."

    # Agent-host connection facts come from config (agent.ssh_extra_args carries
    # a proxy hop when one exists; direct otherwise).
    _agent_ssh_extra="$(cfg agent.ssh_extra_args)"
    _ssh_ok() {   # full multi-RTT handshake (KEX + auth) — the real readiness signal
        # shellcheck disable=SC2086
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 ${_agent_ssh_extra} \
            "${SSH_USER}@${IP}" true 2>/dev/null
    }
    _tcp_ok() {   # SYN/accept on :22 — something is listening even if sshd is settling
        timeout 10 bash -c "exec 3<>/dev/tcp/${IP}/22" 2>/dev/null
    }

    consec=0
    until (( $(date +%s) >= DEADLINE )); do
        elapsed=$(( $(date +%s) - PROBE_T0 ))
        if _ssh_ok; then
            consec=$(( consec + 1 ))
            log "  [+${elapsed}s] full SSH handshake ok (${consec}/${READY_NEED})"
            if (( consec >= READY_NEED )); then
                log "SSH is up on ${IP} (${READY_NEED} consecutive handshakes)."
                exit 0
            fi
            sleep 3
            continue
        fi
        # handshake failed: reset the streak, then classify the blocking layer
        (( consec > 0 )) && warn "  [+${elapsed}s] handshake streak broken (was ${consec}) — path still lossy, restarting count"
        consec=0
        if _tcp_ok; then
            log "  [+${elapsed}s] TCP :22 open but full handshake stalls (banner/KEX settling window)"
        else
            log "  [+${elapsed}s] TCP :22 failing (SYN dropped — path not up yet)"
        fi
        sleep 5
    done
    die "SSH on ${IP} did not reach ${READY_NEED} consecutive handshakes within $(( (DEADLINE - PROBE_T0) / 60 )) min (last layer state logged above)"
fi
