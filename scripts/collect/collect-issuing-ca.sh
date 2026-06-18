#!/usr/bin/env bash
# collect-issuing-ca.sh — Tier-2 RAW dump for the step-ca issuing CA.
# READ-ONLY. Does NOT modify the CA, its provisioners, or any trust artifact.
#
# Dumps (for an agent to judge — naming clarity, scope breadth, chain sanity):
#   - full provisioner list (names, types, JWK/ACME, claims) from the running CA
#   - the authority-level x509 name policy (the wildcard-scope ground truth)
#   - the served-cert subject / issuer chain / SANs (TLS termination truth)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
GROUP="pki_issuing_ca"
collect_header "issuing-ca"

if ! reachable "$GROUP"; then note "host $GROUP unreachable over ssh — no dump"; exit 0; fi

section "step ca provisioner list (full JSON — names, types, JWK/ACME, claims, scopes)"
# The running CA's own view. Names + types here are the acme/acme-1 naming truth.
rssh "$GROUP" \
  "step ca provisioner list --ca-url https://ca.${DOMAIN} \
     --root /etc/step-ca/certs/root_ca.crt 2>/dev/null" 2>/dev/null \
  || note "provisioner list query failed"

section "authority x509 name policy + provisioner config (ca.json — the wildcard-scope ground truth)"
# The authority.policy.x509 allow/allowWildcardNames block is the over-broad
# scope ground truth; per-provisioner claims/options (if any) print alongside.
# encryptedKey / key material is stripped — we want scope, not secrets.
rssh "$GROUP" \
  "cat /etc/step-ca/authorities/*/config/ca.json 2>/dev/null \
     | python3 -c 'import sys,json
d=json.load(sys.stdin)
auth=d.get(\"authority\",{})
out={\"policy\":auth.get(\"policy\"),
     \"provisioners\":[{k:v for k,v in p.items() if k not in (\"encryptedKey\",\"key\")} for p in auth.get(\"provisioners\",[])],
     \"dnsNames\":d.get(\"dnsNames\")}
print(json.dumps(out,indent=2))'" 2>/dev/null \
  || note "ca.json scope query failed"

section "served cert on :443 (subject / issuer chain / SANs)"
rssh "$GROUP" \
  "echo | openssl s_client -connect 127.0.0.1:443 -servername ca.${DOMAIN} 2>/dev/null \
     | openssl x509 -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null" 2>/dev/null \
  || note "served cert query failed"
