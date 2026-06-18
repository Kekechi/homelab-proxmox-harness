#!/usr/bin/env bash
# verify-issuing-ca.sh — Tier-1 behavioral verify for the step-ca issuing CA.
# READ-ONLY. Does NOT modify the CA, its provisioners, or any trust config.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" "issuing-ca"
GROUP="pki_issuing_ca"
hdr

if ! reachable "$GROUP"; then fail "host $GROUP unreachable over ssh"; verify_summary; fi

# 1. Liveness — the systemd unit is active.
unit="$(rssh "$GROUP" 'systemctl is-active step-ca' 2>/dev/null)"
assert "step-ca unit is active" "active" "$unit"

# 2. Behavioral — the served /health endpoint reports ok, validated against the
#    real root CA (proves TLS termination + cert chain, not just a socket).
health="$(rssh "$GROUP" \
  "curl -s --resolve ca.${DOMAIN}:443:127.0.0.1 https://ca.${DOMAIN}/health \
     --cacert /etc/step-ca/certs/root_ca.crt 2>/dev/null" 2>/dev/null)"
if [[ "$health" == *'"status":"ok"'* || "$health" == *'"status": "ok"'* ]]; then
    pass "served /health reports ok (validated against root CA)"
else
    fail "served /health not ok (got: ${health:-<empty>})"
fi

# 3. Behavioral — the provisioner list is reachable from the running CA.
#    (We assert reachability + that an ACME provisioner is live; we do NOT
#    assert specific names — the acme/acme-1 naming is a Tier-2 judgment, and
#    we make no trust-model change here.)
prov="$(rssh "$GROUP" \
  "step ca provisioner list --ca-url https://ca.${DOMAIN} \
     --root /etc/step-ca/certs/root_ca.crt 2>/dev/null" 2>/dev/null)"
if [[ -n "$prov" ]]; then
    pass "provisioner list reachable from running CA"
else
    fail "provisioner list NOT reachable (step ca provisioner list returned empty)"
fi
if [[ "$prov" == *'"ACME"'* ]]; then
    pass "an ACME provisioner is live (cert issuance path present)"
else
    fail "no ACME provisioner in live list (cert issuance would break)"
fi

verify_summary
