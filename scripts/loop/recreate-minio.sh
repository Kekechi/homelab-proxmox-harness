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

NET0="name=eth0,bridge=${BRIDGE},firewall=1,gw=${GATEWAY},ip=${IP}/${PREFIX},type=veth"

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

# --- wait for SSH (through the Squid CONNECT proxy) --------------------------
# Use a real SSH connect rather than an ncat banner grab: the banner can lag
# (reverse-DNS delay while the internal resolver is down) and rebuilt boxes
# present a new host key, so disable host-key checking here.
if [[ "$WAIT_SSH" == 1 ]]; then
    log "Waiting for SSH on ${IP}:22 (via proxy)..."
    SSH_USER="$(cfg services.minio.ansible_user)"; : "${SSH_USER:=root}"
    # A freshly recreated LXC can take several minutes to bring sshd up on the
    # proxy path, and may bounce (a brief reboot/network re-settle) during first
    # boot. The prior ~5-min cap raced that and killed the loop while the box was
    # still settling (observed: host became reachable well after the cap). Wait
    # on a wall-clock deadline and keep retrying across a transient drop.
    DEADLINE=$(( $(date +%s) + 720 ))   # ~12 min
    until (( $(date +%s) >= DEADLINE )); do
        if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
               -o ConnectTimeout=10 \
               -o ProxyCommand="ncat --proxy squid-proxy:3128 --proxy-type http %h %p" \
               "${SSH_USER}@${IP}" true 2>/dev/null; then
            log "SSH is up on ${IP}."
            exit 0
        fi
        sleep 5
    done
    die "SSH on ${IP} did not come up within ~12 min"
fi
