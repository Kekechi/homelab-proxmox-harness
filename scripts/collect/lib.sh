#!/usr/bin/env bash
# =============================================================================
# lib.sh — shared helpers for the Tier-2 collector scripts.
#
# Tier 2 vs Tier 1: the Tier-1 verify scripts (scripts/verify/) make hard
# behavioral ASSERTIONS (exit 0/1). These collectors do the opposite — they
# DUMP raw behavioral state faithfully to stdout (and, when COLLECT_DUMP_DIR is
# set, to a per-service file) and make NO judgment. An agent (driven by the
# /sanity-sweep skill) reads the dumps and judges "working as intended? any
# smell?". Collectors never pass/fail and never act.
#
# Resolution mirrors scripts/verify/lib.sh: host IP + ssh user from the
# generated inventory (ansible/inventory/hosts.yml); domain + toggles from
# config/<env>.yml — the single source of truth.
#
# SSH: uses plain `ssh` (NOT the sandbox-ssh alias) — these run outside Claude
# Code's Bash permission layer (invoked via the skill / make). Read-only only;
# nothing here mutates a host, config, or trust artifact.
# =============================================================================
set -uo pipefail

COLLECT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${COLLECT_LIB_DIR}/../.." && pwd)"
ENV="${ENV:-sandbox}"
CONFIG_FILE="${REPO_ROOT}/config/${ENV}.yml"
INVENTORY_FILE="${REPO_ROOT}/ansible/inventory/hosts.yml"

SSH_OPTS=(-o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=accept-new)

# Optional dump dir. When set, each collector tees its raw output to
# $COLLECT_DUMP_DIR/<svc>.txt as well as stdout. The driver sets this.
COLLECT_DUMP_DIR="${COLLECT_DUMP_DIR:-}"

_c_cyn=$'\033[1;36m'; _c_yel=$'\033[1;33m'; _c_rst=$'\033[0m'

# section <title> — visual separator for a block of raw output.
section() { printf '\n%s----- %s -----%s\n' "$_c_cyn" "$*" "$_c_rst"; }

# note <text> — a collector-side annotation (e.g. "queried via on-disk dir
# because mc is absent"). NOT a judgment — just provenance for the reader.
note()    { printf '%s[note]%s %s\n' "$_c_yel" "$_c_rst" "$*"; }

# --- config / inventory resolution (identical contract to verify/lib.sh) ------
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

DOMAIN="$(cfg domain_name)"

_inv_lookup() {
    local group="$1" field="$2"
    python3 - "$INVENTORY_FILE" "$group" "$field" <<'PY'
import sys, yaml
inv = yaml.safe_load(open(sys.argv[1]))
group, field = sys.argv[2], sys.argv[3]
children = inv.get("all", {}).get("children", {})
g = children.get(group, {})
hosts = g.get("hosts", {}) or {}
for _, h in hosts.items():
    if field in h:
        print(h[field]); break
PY
}
host_ip()   { _inv_lookup "$1" ansible_host; }
host_user() { _inv_lookup "$1" ansible_user; }

# rssh <group> <remote-command> — run a read-only command on the group's host.
rssh() {
    local group="$1"; shift
    local ip user
    ip="$(host_ip "$group")"; user="$(host_user "$group")"
    if [[ -z "$ip" || -z "$user" ]]; then
        return 99
    fi
    ssh "${SSH_OPTS[@]}" "${user}@${ip}" "$@"
}

reachable() {
    local group="$1"
    rssh "$group" 'echo ok' >/dev/null 2>&1
}

# collect_header <svc> — standard banner each collector prints first.
collect_header() {
    printf '======================================================================\n'
    printf 'COLLECT %s  (ENV=%s, domain=%s, %s)\n' "$1" "$ENV" "$DOMAIN" "$(date -u +%FT%TZ)"
    printf 'Tier-2 raw state dump — READ-ONLY, no assertions, no judgment.\n'
    printf '======================================================================\n'
}
