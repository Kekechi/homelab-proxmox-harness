#!/usr/bin/env bash
# collect-dnsdist.sh — Tier-2 RAW dump for DNSdist (client-facing resolver /
# load balancer) and the co-located dns-collector sidecar. READ-ONLY.
#
# Dumps the dnsdist ACLs, configured backends/pools, and the dns-collector
# pipeline config (dnstap receiver -> syslog forwarder).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
GROUP="dns_dist"
collect_header "dnsdist"

if ! reachable "$GROUP"; then note "host $GROUP unreachable over ssh — no dump"; exit 0; fi

section "dnsdist: effective config (raw, non-secret — ACLs, binds, backends, pools)"
# Dump the structural config (yaml), stripping any api_key line.
rssh "$GROUP" \
  'grep -vE "api_key" /etc/dnsdist/dnsdist.yml 2>/dev/null || cat /etc/dnsdist/dnsdist.conf 2>/dev/null' 2>/dev/null \
  | grep -vE 'api_key|secret|password' \
  || note "dnsdist config query failed"

section "dnsdist: live ACL + backends via webserver API"
rssh "$GROUP" \
  'K=$(awk "/^  api_key:/{print \$2}" /etc/dnsdist/dnsdist.yml | tr -d "\""); \
   curl -s -H "X-API-Key: $K" http://127.0.0.1:8083/api/v1/servers/localhost \
     | python3 -c "import sys,json
try:
  d=json.load(sys.stdin)
except Exception:
  print(\"(no JSON from API)\"); sys.exit(0)
out={\"acl\":d.get(\"acl\"),
     \"servers\":[{k:s.get(k) for k in (\"name\",\"address\",\"pool\",\"state\",\"qps\")} for s in d.get(\"servers\",[])],
     \"pools\":d.get(\"pools\")}
print(json.dumps(out,indent=2))"' 2>/dev/null \
  || note "dnsdist API query failed"

section "dns-collector: effective config (dnstap receiver -> syslog forwarder pipeline)"
rssh "$GROUP" \
  'cat /etc/dns-collector/config.yml 2>/dev/null || cat /etc/dnscollector/config.yml 2>/dev/null \
     || find /etc -maxdepth 3 -iname "*.yml" -path "*ns-collector*" -exec cat {} \; 2>/dev/null' 2>/dev/null \
  | grep -vE 'secret|password|token' \
  || note "dns-collector config query failed"
