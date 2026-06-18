#!/usr/bin/env bash
# verify-dnsdist.sh — Tier-1 behavioral verify for DNSdist (client-facing
# resolver / load balancer). READ-ONLY.
# Reuses in-role verify.yml logic (dig via dnsdist + webserver API).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" "dnsdist"
GROUP="dns_dist"
hdr

if ! reachable "$GROUP"; then fail "host $GROUP unreachable over ssh"; verify_summary; fi

# 1. Liveness — the systemd unit is active.
unit="$(rssh "$GROUP" 'systemctl is-active dnsdist' 2>/dev/null)"
assert "dnsdist unit is active" "active" "$unit"

# 2. Behavioral — dnsdist's public :53 actually serves both the internal zone
#    SOA (proves backend forward to the Recursor) and an external name (proves
#    the whole dnsdist -> recursor -> upstream chain).
ip="$(host_ip "$GROUP")"
soa="$(rssh "$GROUP" "dig @${ip} ${DOMAIN} SOA +short 2>/dev/null | head -1" 2>/dev/null)"
assert_nonempty "dnsdist :53 resolves internal SOA for ${DOMAIN}" "$soa"
ext="$(rssh "$GROUP" "dig @${ip} example.com A +short 2>/dev/null | head -1" 2>/dev/null)"
assert_nonempty "dnsdist :53 resolves external name (example.com A)" "$ext"

# 3. Behavioral — the dnsdist webserver API answers (key read from the on-host
#    dnsdist.yml at runtime). Confirms the control/metrics plane is live.
acode="$(rssh "$GROUP" \
  'K=$(awk "/^  api_key:/{print \$2}" /etc/dnsdist/dnsdist.yml | tr -d "\""); \
   curl -s -o /dev/null -w "%{http_code}" -H "X-API-Key: $K" \
     http://127.0.0.1:8083/api/v1/servers/localhost' 2>/dev/null)"
assert "dnsdist webserver API returns 200" "200" "$acode"

verify_summary
