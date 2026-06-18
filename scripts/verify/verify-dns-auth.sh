#!/usr/bin/env bash
# verify-dns-auth.sh — Tier-1 behavioral verify for PowerDNS Authoritative +
# Recursor (co-deployed on the dns_auth host). READ-ONLY.
# Reuses in-role verify.yml logic (API health + zone presence + dig).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" "dns-auth"
GROUP="dns_auth"
hdr

if ! reachable "$GROUP"; then fail "host $GROUP unreachable over ssh"; verify_summary; fi

# 1. Liveness — both daemons active.
au="$(rssh "$GROUP" 'systemctl is-active pdns' 2>/dev/null)"
ru="$(rssh "$GROUP" 'systemctl is-active pdns-recursor' 2>/dev/null)"
assert "pdns (auth) unit is active" "active" "$au"
assert "pdns-recursor unit is active" "active" "$ru"

# 2. Behavioral — Auth API up AND the internal zone object exists (the served
#    zone, not the config). API key read from the on-host pdns.conf at runtime.
acode="$(rssh "$GROUP" \
  'K=$(grep -h "^api-key=" /etc/powerdns/pdns.conf | cut -d= -f2-); \
   curl -s -o /dev/null -w "%{http_code}" -H "X-API-Key: $K" \
     http://127.0.0.1:8081/api/v1/servers/localhost' 2>/dev/null)"
assert "auth API health returns 200" "200" "$acode"

zcode="$(rssh "$GROUP" \
  'K=$(grep -h "^api-key=" /etc/powerdns/pdns.conf | cut -d= -f2-); \
   curl -s -o /dev/null -w "%{http_code}" -H "X-API-Key: $K" \
     http://127.0.0.1:8081/api/v1/servers/localhost/zones/'"${DOMAIN}"'.' 2>/dev/null)"
assert "internal zone ${DOMAIN}. served by Auth" "200" "$zcode"

# 3. Behavioral — Recursor API up.
rcode="$(rssh "$GROUP" \
  'K=$(grep -h "^api-key=" /etc/powerdns/recursor.conf | cut -d= -f2-); \
   curl -s -o /dev/null -w "%{http_code}" -H "X-API-Key: $K" \
     http://127.0.0.1:8082/api/v1/servers/localhost' 2>/dev/null)"
assert "recursor API health returns 200" "200" "$rcode"

# 4. Behavioral — the Recursor actually resolves the internal zone SOA and an
#    external name (proves the auth-zone forward AND upstream recursion work).
ip="$(host_ip "$GROUP")"
soa="$(rssh "$GROUP" "dig @${ip} ${DOMAIN} SOA +short 2>/dev/null | head -1" 2>/dev/null)"
assert_nonempty "recursor resolves internal SOA for ${DOMAIN}" "$soa"
ext="$(rssh "$GROUP" "dig @${ip} example.com A +short 2>/dev/null | head -1" 2>/dev/null)"
assert_nonempty "recursor resolves external name (example.com A)" "$ext"

verify_summary
