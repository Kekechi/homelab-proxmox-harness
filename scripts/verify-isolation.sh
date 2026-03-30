#!/usr/bin/env bash
# =============================================================================
# verify-isolation.sh — Network isolation verification
#
# Run inside the dev container to verify:
#   1. Required tools are present
#   2. Direct internet access is blocked (internal:true network is working)
#   3. Squid proxy allows required destinations
#   4. Squid proxy blocks unauthorized destinations
#   5. MinIO is reachable through Squid
#   6. Sandbox Proxmox is reachable through Squid
#
# Usage:
#   bash scripts/verify-isolation.sh
#   make verify-isolation
# =============================================================================

set -uo pipefail

PASS=0
FAIL=0
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✓${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}✗${NC} $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "  ${YELLOW}→${NC} $1"; }

echo ""
echo "=== Homelab Proxmox Harness — Isolation Verification ==="
echo ""

# ---------------------------------------------------------------------------
# 1. Tool presence
# ---------------------------------------------------------------------------
echo "── Tool checks ──────────────────────────────────────────"

for tool in terraform ansible tflint ncat curl; do
    if command -v "${tool}" &>/dev/null; then
        pass "${tool} found: $(${tool} --version 2>&1 | head -1)"
    else
        fail "${tool} not found"
    fi
done

# ---------------------------------------------------------------------------
# 2. Direct internet blocked (internal:true network)
# ---------------------------------------------------------------------------
echo ""
echo "── Network isolation ────────────────────────────────────"

if curl --connect-timeout 3 --silent --output /dev/null "https://google.com" 2>/dev/null; then
    fail "CRITICAL: Direct internet access is NOT blocked — internal:true may not be working on WSL2"
    info "Check WSL2 networking mode (.wslconfig). NAT mode required, not mirrored."
else
    pass "Direct internet access is blocked (internal:true working)"
fi

# ---------------------------------------------------------------------------
# 3. Squid proxy is reachable
# ---------------------------------------------------------------------------
if ! curl --connect-timeout 5 --silent --output /dev/null \
    --proxy "http://squid-proxy:3128" "http://squid-proxy:3128"; then
    fail "Squid proxy not reachable at squid-proxy:3128"
else
    pass "Squid proxy reachable"
fi

# ---------------------------------------------------------------------------
# 4. Squid allows: Terraform registry
# ---------------------------------------------------------------------------
HTTP_CODE=$(curl --connect-timeout 10 --silent --output /dev/null \
    --write-out "%{http_code}" \
    --proxy "http://squid-proxy:3128" \
    "https://registry.terraform.io" 2>/dev/null || echo "000")
if [[ "${HTTP_CODE}" =~ ^[23] ]]; then
    pass "Squid allows registry.terraform.io (HTTP ${HTTP_CODE})"
else
    fail "Squid blocked registry.terraform.io (HTTP ${HTTP_CODE}) — check squid.conf"
fi

# ---------------------------------------------------------------------------
# 5. Squid blocks: unauthorized domain
# ---------------------------------------------------------------------------
HTTP_CODE=$(curl --connect-timeout 5 --silent --output /dev/null \
    --write-out "%{http_code}" \
    --proxy "http://squid-proxy:3128" \
    "https://google.com" 2>/dev/null || echo "000")
if [[ "${HTTP_CODE}" == "403" ]] || [[ "${HTTP_CODE}" == "000" ]]; then
    pass "Squid correctly blocks google.com (HTTP ${HTTP_CODE})"
else
    fail "Squid did NOT block google.com (HTTP ${HTTP_CODE}) — ACL may be misconfigured"
fi

# ---------------------------------------------------------------------------
# 6. MinIO reachable through Squid
# ---------------------------------------------------------------------------
echo ""
echo "── Service connectivity ─────────────────────────────────"

if [[ -z "${MINIO_ENDPOINT:-}" ]]; then
    info "MINIO_ENDPOINT not set — skipping MinIO check (set in .envrc)"
else
    HTTP_CODE=$(curl --connect-timeout 10 --silent --output /dev/null \
        --write-out "%{http_code}" \
        --proxy "http://squid-proxy:3128" \
        "${MINIO_ENDPOINT}/minio/health/live" 2>/dev/null || echo "000")
    if [[ "${HTTP_CODE}" =~ ^[23] ]]; then
        pass "MinIO reachable through Squid at ${MINIO_ENDPOINT} (HTTP ${HTTP_CODE})"
    else
        fail "MinIO not reachable through Squid at ${MINIO_ENDPOINT} (HTTP ${HTTP_CODE})"
        info "Check: Is MinIO running? Is its IP in allowed-cidrs.conf? Was squid-proxy rebuilt?"
    fi
fi

# ---------------------------------------------------------------------------
# 7. Proxmox sandbox reachable through Squid
# ---------------------------------------------------------------------------
if [[ -z "${PROXMOX_VE_ENDPOINT:-}" ]]; then
    info "PROXMOX_VE_ENDPOINT not set — skipping Proxmox check (set in .envrc)"
else
    HTTP_CODE=$(curl --connect-timeout 10 --silent --output /dev/null \
        --write-out "%{http_code}" \
        --proxy "http://squid-proxy:3128" \
        --insecure \
        "${PROXMOX_VE_ENDPOINT}api2/json" 2>/dev/null || echo "000")
    if [[ "${HTTP_CODE}" =~ ^[23] ]] || [[ "${HTTP_CODE}" == "401" ]]; then
        pass "Sandbox Proxmox reachable through Squid at ${PROXMOX_VE_ENDPOINT} (HTTP ${HTTP_CODE})"
    else
        fail "Sandbox Proxmox not reachable through Squid (HTTP ${HTTP_CODE})"
        info "Check: Is the sandbox VLAN CIDR in allowed-cidrs.conf? Was squid-proxy rebuilt?"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "─────────────────────────────────────────────────────────"
echo -e "  Results: ${GREEN}${PASS} passed${NC}  ${RED}${FAIL} failed${NC}"
echo ""

if [[ ${FAIL} -gt 0 ]]; then
    echo -e "  ${RED}Isolation verification FAILED.${NC}"
    echo "  Fix the issues above before proceeding with Terraform or Ansible."
    exit 1
else
    echo -e "  ${GREEN}All checks passed. Isolation is working correctly.${NC}"
fi
echo ""
