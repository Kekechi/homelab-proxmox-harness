#!/usr/bin/env bash
# =============================================================================
# lib.sh — shared helpers for the Tier-1 per-service verify scripts
#
# These scripts query the LIVE, running daemon (behavioral-over-file): they
# assert what the service is actually doing, not what its config file says it
# should do. Each verify-<svc>.sh produces a hard exit 0 (all assertions pass)
# or exit 1 (any assertion failed).
#
# Resolution: host IP + ssh user come from the generated inventory
# (ansible/inventory/hosts.yml); the splunk.enabled toggle + domain come from
# config/<env>.yml — the single source of truth, same place ansible resolves.
#
# SSH: uses plain `ssh` (NOT the sandbox-ssh alias). These scripts run outside
# Claude Code's Bash permission layer (invoked via make / the loop), so they
# must use plain ssh — per the repo convention in CLAUDE.md. Read-only queries
# only; nothing here mutates a host.
# =============================================================================
set -uo pipefail

VERIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${VERIFY_LIB_DIR}/../.." && pwd)"
ENV="${ENV:-sandbox}"
CONFIG_FILE="${REPO_ROOT}/config/${ENV}.yml"
INVENTORY_FILE="${REPO_ROOT}/ansible/inventory/hosts.yml"

SSH_OPTS=(-o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=accept-new)

# --- output helpers ----------------------------------------------------------
_c_grn=$'\033[0;32m'; _c_red=$'\033[0;31m'; _c_yel=$'\033[1;33m'
_c_cyn=$'\033[1;36m'; _c_rst=$'\033[0m'

# Per-script assertion accounting. A script sources this, runs checks via
# pass/fail, then calls verify_summary at the end to set the exit code.
_FAILS=0
_SVC="${1:-service}"

hdr()  { printf '%s== verify-%s ==%s\n' "$_c_cyn" "$_SVC" "$_c_rst"; }
pass() { printf '  %s[PASS]%s %s\n' "$_c_grn" "$_c_rst" "$*"; }
fail() { printf '  %s[FAIL]%s %s\n' "$_c_red" "$_c_rst" "$*"; _FAILS=$((_FAILS+1)); }
skip() { printf '  %s[SKIP]%s %s\n' "$_c_yel" "$_c_rst" "$*"; }
info() { printf '  %s[ .. ]%s %s\n' "$_c_cyn" "$_c_rst" "$*"; }

# assert <description> <expected> <actual> — pass iff expected == actual.
assert() {
    local desc="$1" exp="$2" act="$3"
    if [[ "$exp" == "$act" ]]; then
        pass "${desc} (got: ${act})"
    else
        fail "${desc} (expected: ${exp}, got: ${act:-<empty>})"
    fi
}

# assert_nonempty <description> <actual>
assert_nonempty() {
    local desc="$1" act="$2"
    if [[ -n "${act// /}" ]]; then
        pass "${desc} (got: ${act})"
    else
        fail "${desc} (expected non-empty, got: <empty>)"
    fi
}

verify_summary() {
    if [[ "$_FAILS" -eq 0 ]]; then
        printf '%s== verify-%s: PASS ==%s\n' "$_c_grn" "$_SVC" "$_c_rst"
        exit 0
    fi
    printf '%s== verify-%s: FAIL (%d assertion(s) failed) ==%s\n' "$_c_red" "$_SVC" "$_FAILS" "$_c_rst"
    exit 1
}

# --- config / inventory resolution -------------------------------------------
# cfg <dotted.path> — scalar from config/<env>.yml, or empty (mirrors loop/lib.sh).
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

# host_ip <inventory-group> / host_user <inventory-group> — resolves the (single)
# host in a group to its ansible_host / ansible_user from the generated inventory.
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
# Resolves user@ip from the inventory. Returns the command's stdout + exit code.
rssh() {
    local group="$1"; shift
    local ip user
    ip="$(host_ip "$group")"; user="$(host_user "$group")"
    if [[ -z "$ip" || -z "$user" ]]; then
        return 99
    fi
    ssh "${SSH_OPTS[@]}" "${user}@${ip}" "$@"
}

# reachable <group> — quick liveness gate before running per-service assertions.
reachable() {
    local group="$1"
    rssh "$group" 'echo ok' >/dev/null 2>&1
}
