#!/usr/bin/env bash
# =============================================================================
# verify.sh — capture live evidence from the rebuilt hosts
#
# The loop's verification step. Reasoning from general knowledge is not enough;
# this captures ACTUAL state: apt reachability (the cold-start apt/TLS test),
# the CA trust store contents + issuer, and service unit status. Output is
# evidence to read, not a pass/fail gate (it never hard-fails the loop).
#
# Usage: bash scripts/loop/verify.sh [ENV]
# =============================================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV="${1:-${ENV:-sandbox}}"
export ENV
# shellcheck source=lib.sh
source "${SELF_DIR}/lib.sh"

export ANSIBLE_HOST_KEY_CHECKING=False
cd "${REPO_ROOT}/ansible"

run() { printf '\n\033[1;35m--- %s ---\033[0m\n' "$1" >&2; shift; "$@" 2>&1 || true; }

# 1. Reachability — who answers at all.
run "reachability (ping module)" \
    ansible all -i inventory/ -m ping -o

# 2. apt health — the cold-start signal. A failure here with a TLS/CA or
#    Nexus-unreachable error is the WS1 breakage captured live.
run "apt-get update (cold-start apt/TLS test)" \
    ansible all -i inventory/ -b -m shell -a 'apt-get update 2>&1 | tail -n 25; echo "EXIT=${PIPESTATUS[0]}"'

# 3. CA trust store — is the homelab root actually installed + what is it.
run "system CA trust (homelab root present?)" \
    ansible all -i inventory/ -b -m shell -a \
    'ls -1 /usr/local/share/ca-certificates/ 2>/dev/null; \
     awk -v cmd="openssl x509 -noout -issuer 2>/dev/null" "/BEGIN/{c=0} {print | cmd}" /etc/ssl/certs/ca-certificates.crt 2>/dev/null | grep -i homelab | head -3 || true'

# 4. Service units — what is actually up.
run "service unit status" \
    ansible all -i inventory/ -b -m shell -a \
    'systemctl is-system-running 2>/dev/null; \
     for u in step-ca nexus pdns pdns-recursor dnsdist nginx minio; do \
        printf "%-16s %s\n" "$u" "$(systemctl is-active "$u" 2>/dev/null || echo n/a)"; \
     done'

printf '\n\033[1;35m--- verify complete (evidence above) ---\033[0m\n' >&2
