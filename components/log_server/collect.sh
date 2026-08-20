#!/usr/bin/env bash
# collect-log-server.sh — Tier-2 RAW dump for the otelcol-contrib log server
# (syslog receivers -> awss3 MinIO sink) and the otelcol effective pipeline.
# READ-ONLY.
#
# Dumps the effective otelcol config (receivers / processors / exporters /
# pipelines) with secrets stripped, plus the bound listener sockets.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/collect/lib.sh"
GROUP="log_server"
collect_header "log-server"

if ! reachable "$GROUP"; then note "host $GROUP unreachable over ssh — no dump"; exit 0; fi

section "otelcol effective config (receivers / processors / exporters / pipelines)"
# The running config is the pipeline ground truth. Strip credential-bearing
# lines (access keys / secrets / tokens) — we want topology, not secrets.
rssh "$GROUP" \
  'cat /etc/otelcol-contrib/config.yaml 2>/dev/null' 2>/dev/null \
  | grep -viE 'secret|access_key|secret_key|password|token|hec_token|api_key' \
  || note "otelcol config query failed"

section "otelcol: pipeline structure (parsed — which receivers/processors/exporters per pipeline)"
# Convenience parse. PyYAML may be absent on the host (otelcol ships no python
# deps); if so this is skipped — the full effective config above is the
# authoritative dump and already shows the pipeline wiring.
parsed="$(rssh "$GROUP" \
  'python3 -c "import yaml,json,sys
c=yaml.safe_load(open(\"/etc/otelcol-contrib/config.yaml\"))
out={\"receivers\":list((c.get(\"receivers\") or {}).keys()),
     \"processors\":list((c.get(\"processors\") or {}).keys()),
     \"exporters\":list((c.get(\"exporters\") or {}).keys()),
     \"pipelines\":{k:{\"receivers\":v.get(\"receivers\"),\"processors\":v.get(\"processors\"),\"exporters\":v.get(\"exporters\")} for k,v in ((c.get(\"service\") or {}).get(\"pipelines\") or {}).items()}}
print(json.dumps(out,indent=2))" 2>/dev/null' 2>/dev/null)"
if [[ -n "$parsed" ]]; then
    printf '%s\n' "$parsed"
else
    note "convenience parse skipped (PyYAML absent on host) — see full effective config above for pipeline wiring"
fi

section "otelcol: bound listener sockets (ss -tlnp, otelcol-owned)"
rssh "$GROUP" 'ss -tlnp 2>/dev/null | grep otelcol' 2>/dev/null \
  || note "socket query failed"

section "dns_collector config on this host (if co-located)"
rssh "$GROUP" \
  'cat /etc/dns-collector/config.yml 2>/dev/null || echo "(no dns_collector on log-server host)"' 2>/dev/null \
  | grep -viE 'secret|password|token' \
  || note "dns_collector check skipped"
