#!/usr/bin/env bash
# verify-dns-collector.sh — Tier-1 behavioral verify for the dns-collector
# sidecar (DNSTap receiver -> syslog forwarder), co-located on the dns_dist
# host. READ-ONLY.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" "dns-collector"
GROUP="dns_dist"
hdr

if ! reachable "$GROUP"; then fail "host $GROUP unreachable over ssh"; verify_summary; fi

# 1. Liveness — the systemd unit is active (the role's own verify signal).
unit="$(rssh "$GROUP" 'systemctl is-active dns-collector' 2>/dev/null)"
assert "dns-collector unit is active" "active" "$unit"

# 2. Behavioral — the DNSTap receiver socket is actually bound on 127.0.0.1:6000
#    by the dnscollector process (proves it is listening for dnsdist frames, not
#    merely running). dns-collector has no HTTP health endpoint, so the bound
#    listener is the strongest live behavioral signal available.
listen="$(rssh "$GROUP" \
  'ss -tlnp 2>/dev/null | grep -E "127.0.0.1:6000" | grep -c dnscollector' 2>/dev/null)"
if [[ "${listen:-0}" -ge 1 ]]; then
    pass "dnstap receiver bound on 127.0.0.1:6000 by dnscollector"
else
    fail "dnstap receiver NOT bound on 127.0.0.1:6000 (collector not listening)"
fi

verify_summary
