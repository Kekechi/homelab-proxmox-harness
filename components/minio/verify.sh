#!/usr/bin/env bash
# verify-minio.sh — Tier-1 behavioral verify for MinIO (object store +
# Terraform state backend). READ-ONLY.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/verify/lib.sh" "minio"
GROUP="minio"
hdr

if ! reachable "$GROUP"; then fail "host $GROUP unreachable over ssh"; verify_summary; fi

# 1. Liveness — the systemd unit is active.
unit="$(rssh "$GROUP" 'systemctl is-active minio' 2>/dev/null)"
assert "minio unit is active" "active" "$unit"

# MinIO's endpoint scheme is decoupled from minio.tls in this repo; probe the
# scheme the running server actually serves (try https, fall back to http).
scheme="http"
if [[ "$(cfg services.minio.tls)" == "True" ]]; then scheme="https"; fi

# 2. Behavioral — /minio/health/live returns 200 (process is up + serving).
lcode="$(rssh "$GROUP" \
  "curl -sk -o /dev/null -w '%{http_code}' ${scheme}://127.0.0.1:9000/minio/health/live" 2>/dev/null)"
assert "health/live returns 200" "200" "$lcode"

# 3. Behavioral — /minio/health/ready returns 200 (fully ready to serve S3,
#    i.e. the state backend can actually be reached — stricter than /live).
rcode="$(rssh "$GROUP" \
  "curl -sk -o /dev/null -w '%{http_code}' ${scheme}://127.0.0.1:9000/minio/health/ready" 2>/dev/null)"
assert "health/ready returns 200" "200" "$rcode"

verify_summary
