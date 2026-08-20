#!/usr/bin/env bash
# collect-nexus.sh — Tier-2 RAW dump for Nexus Repository Manager.
# READ-ONLY. Dumps repositories, roles/privileges, and the apt-proxy config.
#
# Admin reads need creds: if NEXUS_ADMIN_PASSWORD is in the environment they are
# used; otherwise the public repository-browse path is dumped and the privileged
# sections note that creds were absent (so the reader knows the dump is partial).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/collect/lib.sh"
GROUP="nexus"
collect_header "nexus"

if ! reachable "$GROUP"; then note "host $GROUP unreachable over ssh — no dump"; exit 0; fi

P="${NEXUS_ADMIN_PASSWORD:-}"
B="http://127.0.0.1:8081/service/rest/v1"

if [[ -z "$P" ]]; then
    note "NEXUS_ADMIN_PASSWORD not in env — admin sections fall back to public browse / are skipped"
fi

section "repositories (raw — names, formats, type proxy/hosted/group, remote URLs)"
if [[ -n "$P" ]]; then
    rssh "$GROUP" "curl -s -u 'admin:$P' $B/repositories" 2>/dev/null || note "repositories query failed"
else
    rssh "$GROUP" "curl -s http://127.0.0.1:8081/service/rest/repository/browse/" 2>/dev/null \
      || note "public repo-browse query failed"
fi

section "apt-proxy repo detail (the cold-start contract repo — remote, distribution, flat)"
if [[ -n "$P" ]]; then
    rssh "$GROUP" "curl -s -u 'admin:$P' $B/repositories \
       | python3 -c 'import sys,json
try:
  rs=json.load(sys.stdin)
except Exception:
  print(\"(non-JSON response)\"); sys.exit(0)
for r in rs if isinstance(rs,list) else []:
  if r.get(\"format\")==\"apt\" or \"apt\" in r.get(\"name\",\"\"):
    print(json.dumps(r,indent=2))'" 2>/dev/null || note "apt-proxy detail query failed"
else
    note "skipped — needs admin creds"
fi

section "roles (raw — id, name, privileges, nested roles)"
if [[ -n "$P" ]]; then
    rssh "$GROUP" "curl -s -u 'admin:$P' $B/security/roles" 2>/dev/null || note "roles query failed"
else
    note "skipped — needs admin creds"
fi

section "privileges (raw — granted actions per privilege; over-broad grants are a smell)"
if [[ -n "$P" ]]; then
    rssh "$GROUP" "curl -s -u 'admin:$P' $B/security/privileges" 2>/dev/null || note "privileges query failed"
else
    note "skipped — needs admin creds"
fi

section "users (raw — id, roles, source; default/anonymous status)"
if [[ -n "$P" ]]; then
    rssh "$GROUP" "curl -s -u 'admin:$P' $B/security/users" 2>/dev/null || note "users query failed"
else
    note "skipped — needs admin creds"
fi
