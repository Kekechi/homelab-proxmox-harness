#!/usr/bin/env bash
# collect-dns-auth.sh — Tier-2 RAW dump for PowerDNS Authoritative + Recursor
# (co-deployed on the dns_auth host). READ-ONLY.
#
# Dumps zones served by Auth, the records in the internal zone, and the
# Recursor's forward/backend configuration — the resolver-topology ground truth.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
GROUP="dns_auth"
collect_header "dns-auth"

if ! reachable "$GROUP"; then note "host $GROUP unreachable over ssh — no dump"; exit 0; fi

section "Auth: zones served (raw — names, kinds, serials)"
rssh "$GROUP" \
  'K=$(grep -h "^api-key=" /etc/powerdns/pdns.conf | cut -d= -f2-); \
   curl -s -H "X-API-Key: $K" http://127.0.0.1:8081/api/v1/servers/localhost/zones' 2>/dev/null \
  || note "auth zones query failed"

section "Auth: internal zone ${DOMAIN}. record set (raw RRsets)"
rssh "$GROUP" \
  'K=$(grep -h "^api-key=" /etc/powerdns/pdns.conf | cut -d= -f2-); \
   curl -s -H "X-API-Key: $K" http://127.0.0.1:8081/api/v1/servers/localhost/zones/'"${DOMAIN}"'.' 2>/dev/null \
  || note "auth zone detail query failed"

section "Recursor: effective config (raw, non-secret — forward_zones, listen, allow_from)"
# PowerDNS Recursor 5.x uses YAML (recursor.yml) + an optional recursor.d/ drop-in
# dir; older builds used key=value recursor.conf. Dump whichever is present, with
# any api/secret/password line stripped. This is the resolver-backend ground truth.
rssh "$GROUP" \
  'for f in /etc/powerdns/recursor.yml /etc/powerdns/recursor.conf; do \
     [ -f "$f" ] && { echo "# --- $f ---"; grep -vE "^\s*#" "$f"; }; \
   done; \
   if [ -d /etc/powerdns/recursor.d ] && ls /etc/powerdns/recursor.d/* >/dev/null 2>&1; then \
     echo "# --- recursor.d/ drop-ins ---"; grep -rvE "^\s*#" /etc/powerdns/recursor.d/ 2>/dev/null; \
   fi' 2>/dev/null \
  | grep -viE 'api.?key|api_key|secret|password' \
  || note "recursor config query failed"
