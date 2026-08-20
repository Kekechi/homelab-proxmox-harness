#!/usr/bin/env bash
# =============================================================================
# lib.sh — shared helpers for the destroy→rebuild verification loop
#
# Sourced by the scripts under scripts/loop/. Provides:
#   - .envrc sourcing (the only readable path to PROXMOX_VE_* / MINIO_* secrets)
#   - Proxmox API endpoint normalisation + a curl wrapper (pve_api)
#   - config/<env>.yml value extraction (cfg)
#
# Everything here is read-only against the environment except pve_api callers.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV="${ENV:-sandbox}"
CONFIG_FILE="${REPO_ROOT}/config/${ENV}.yml"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- secrets -----------------------------------------------------------------
# .envrc is intentionally unreadable via cat/grep (anti-leak). Sourcing is the
# supported path: it puts PROXMOX_VE_* / MINIO_* into the environment.
load_envrc() {
    [[ -f "${REPO_ROOT}/.envrc" ]] || die ".envrc not found — run 'make configure' and fill in secrets first"
    set -a
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/.envrc"
    set +a
}

# --- config ------------------------------------------------------------------
# cfg <dotted.path>  → prints the scalar value from config/<env>.yml, or empty.
cfg() {
    python3 - "$CONFIG_FILE" "$1" <<'PY'
import os, sys, yaml
path = sys.argv[2].split(".")
with open(sys.argv[1]) as f:
    node = yaml.safe_load(f)
# Deep-merge the private overlay (<env>.local.yml) — same semantics as genconfig.
local_path = sys.argv[1].replace(".yml", ".local.yml")
if os.path.exists(local_path):
    def merge(a, b):
        out = dict(a)
        for k, v in b.items():
            out[k] = merge(out[k], v) if isinstance(v, dict) and isinstance(out.get(k), dict) else v
        return out
    with open(local_path) as f:
        node = merge(node, yaml.safe_load(f) or {})
for key in path:
    if isinstance(node, dict) and key in node:
        node = node[key]
    else:
        sys.exit(0)
if node is None:
    sys.exit(0)
print(node)
PY
}

# --- Proxmox API -------------------------------------------------------------
_pve_init() {
    : "${PROXMOX_VE_ENDPOINT:?source .envrc first (call load_envrc)}"
    : "${PROXMOX_VE_API_TOKEN:?source .envrc first (call load_envrc)}"
    # Normalise: strip trailing slash and any /api2/json suffix, then re-add it.
    local base="${PROXMOX_VE_ENDPOINT%/}"
    base="${base%/api2/json}"
    PVE_API="${base}/api2/json"
    PVE_AUTH="Authorization: PVEAPIToken=${PROXMOX_VE_API_TOKEN}"
}

# pve_api <METHOD> <path> [curl-data-args...]
# path begins with /  (e.g. /cluster/resources?type=vm)
pve_api() {
    [[ -n "${PVE_API:-}" ]] || _pve_init
    local method="$1"; shift
    local path="$1"; shift
    curl -sS -k -X "$method" \
        -H "$PVE_AUTH" \
        "$@" \
        "${PVE_API}${path}"
}

# pool_id / vmid range from config — used for teardown scoping + safety asserts.
# Required (no hardcoded fallback): a wrong/empty pool scope must fail loud, and
# the real names are environment topology that does not belong in a public repo.
POOL_ID="$(cfg terraform.pool_id)"
VMID_START="$(cfg terraform.vm_id_range_start)"
[[ -n "$POOL_ID"    ]] || die "terraform.pool_id not set in ${CONFIG_FILE}"
[[ -n "$VMID_START" ]] || die "terraform.vm_id_range_start not set in ${CONFIG_FILE}"
# Sandbox guests live in [VMID_START, VMID_START+99]; templates sit at 9000+.
VMID_MIN="${VMID_START}"
VMID_MAX="$(( VMID_START + 99 ))"
