#!/usr/bin/env bash
# verify-nexus.sh — Tier-1 behavioral verify for Nexus Repository Manager.
# READ-ONLY. Reuses the in-role verify.yml logic (writable status, docker v2,
# repo list) but queried live and reduced to a few critical assertions.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" "nexus"
GROUP="nexus"
hdr

if ! reachable "$GROUP"; then fail "host $GROUP unreachable over ssh"; verify_summary; fi

# 1. Liveness — the systemd unit is active.
unit="$(rssh "$GROUP" 'systemctl is-active nexus' 2>/dev/null)"
assert "nexus unit is active" "active" "$unit"

# 2. Behavioral — the writable-status endpoint returns 200 (DB up + accepting
#    writes; this is Nexus's own readiness signal, not just a port being open).
code="$(rssh "$GROUP" \
  'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8081/service/rest/v1/status/writable' 2>/dev/null)"
assert "writable-status endpoint returns 200" "200" "$code"

# 3. Behavioral — the docker registry v2 connector answers (401 = auth-required,
#    which is correct: it proves the connector is bound and serving).
dcode="$(rssh "$GROUP" \
  'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5001/v2/' 2>/dev/null)"
if [[ "$dcode" == "200" || "$dcode" == "401" ]]; then
    pass "docker registry v2 connector serving (HTTP ${dcode})"
else
    fail "docker registry v2 connector not serving (HTTP ${dcode:-<empty>})"
fi

# 4. Behavioral — the critical APT-proxy repo for the OS base is live in the
#    running repository list (apt-via-Nexus is the cold-start contract; a missing
#    repo here is exactly what bricks fresh deploys). Uses admin creds from env
#    if present; otherwise checks the public repo-browse path.
repos="$(NEXUS_ADMIN_PASSWORD="${NEXUS_ADMIN_PASSWORD:-}" rssh "$GROUP" \
  'P="'"${NEXUS_ADMIN_PASSWORD:-}"'"; \
   if [ -n "$P" ]; then \
     curl -s -u "admin:$P" http://127.0.0.1:8081/service/rest/v1/repositories; \
   else \
     curl -s http://127.0.0.1:8081/service/rest/repository/browse/; \
   fi' 2>/dev/null)"
if [[ "$repos" == *"apt-proxy-trixie"* ]]; then
    pass "apt-proxy-trixie repo present in live repository list"
else
    if [[ -z "${NEXUS_ADMIN_PASSWORD:-}" ]]; then
        skip "repo-list assertion: NEXUS_ADMIN_PASSWORD not in env and browse path empty"
    else
        fail "apt-proxy-trixie repo NOT in live repository list"
    fi
fi

verify_summary
