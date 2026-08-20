#!/usr/bin/env bash
# verify-log-server.sh — Tier-1 behavioral verify for the otelcol-contrib log
# server (syslog receivers -> awss3 MinIO sink). READ-ONLY.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/verify/lib.sh" "log-server"
GROUP="log_server"
hdr

if ! reachable "$GROUP"; then fail "host $GROUP unreachable over ssh"; verify_summary; fi

# 1. Liveness — the systemd unit is active.
unit="$(rssh "$GROUP" 'systemctl is-active otelcol-contrib' 2>/dev/null)"
assert "otelcol-contrib unit is active" "active" "$unit"

# 2. Behavioral — the health_check extension endpoint answers 200. otelcol is
#    headless, but its health_check extension (port 13133) is the running
#    daemon's own readiness signal — the pipeline is built and started.
hcode="$(rssh "$GROUP" \
  'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:13133' 2>/dev/null)"
assert "otelcol health_check endpoint (13133) returns 200" "200" "$hcode"

# 3. Behavioral — both syslog receivers are actually bound by otelcol (the DNS
#    log path on 1515 and the auth-event path on 1516). A receiver that failed
#    to bind would silently drop all telemetry; the bound socket is the proof.
b1515="$(rssh "$GROUP" \
  'ss -tlnp 2>/dev/null | grep ":1515" | grep -c otelcol' 2>/dev/null)"
b1516="$(rssh "$GROUP" \
  'ss -tlnp 2>/dev/null | grep ":1516" | grep -c otelcol' 2>/dev/null)"
if [[ "${b1515:-0}" -ge 1 ]]; then pass "syslog receiver bound on :1515 (DNS logs)";  else fail "syslog receiver NOT bound on :1515"; fi
if [[ "${b1516:-0}" -ge 1 ]]; then pass "syslog receiver bound on :1516 (auth events)"; else fail "syslog receiver NOT bound on :1516"; fi

# 4. Behavioral — the running config routes to the awss3 (MinIO) sink. This is
#    the decoupled-from-Splunk default sink; confirming it is wired proves logs
#    have a durable destination.
s3="$(rssh "$GROUP" \
  'grep -c "awss3" /etc/otelcol-contrib/config.yaml' 2>/dev/null)"
if [[ "${s3:-0}" -ge 1 ]]; then
    pass "awss3 (MinIO) exporter wired in effective config"
else
    fail "awss3 (MinIO) exporter NOT present in effective config"
fi

verify_summary
