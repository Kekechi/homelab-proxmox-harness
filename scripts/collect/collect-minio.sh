#!/usr/bin/env bash
# collect-minio.sh — Tier-2 RAW dump for MinIO (object store + Terraform state
# backend). READ-ONLY.
#
# IMPORTANT — query path differs from the other collectors. MinIO's IAM is
# encrypted at rest on-disk and the `mc`/`mcli` client is NOT installed on the
# MinIO host, so on-host reads cannot yield raw policy. The authoritative
# read-only path is the `mcli` admin API from where the client lives (the dev
# container, which already has a configured alias). This collector therefore
# runs `mcli` LOCALLY against $COLLECT_MINIO_ALIAS (default homelab-minio-sandbox)
# rather than over ssh. All commands are read-only (admin info / policy / user
# list + bucket ls). Falls back to a noted on-host inventory if mcli is absent.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
GROUP="minio"
collect_header "minio"

ALIAS="${COLLECT_MINIO_ALIAS:-homelab-minio-sandbox}"

if command -v mcli >/dev/null 2>&1; then
    MC=mcli
elif command -v mc >/dev/null 2>&1; then
    MC=mc
else
    MC=""
fi

if [[ -n "$MC" ]]; then
    note "querying via '$MC' admin API against alias '$ALIAS' (read-only)"

    section "mcli admin info (cluster status, servers, capacity, drives)"
    "$MC" admin info "$ALIAS" 2>&1 || note "admin info failed"

    section "buckets (raw ls — the state backend + log sink live here)"
    "$MC" ls "$ALIAS" 2>&1 || note "bucket ls failed"

    section "IAM: canned + custom policy names (raw)"
    "$MC" admin policy list "$ALIAS" 2>&1 || note "policy list failed"

    section "IAM: custom policy documents (the actual granted actions — over-broad = smell)"
    # Dump the JSON of each non-canned policy. Canned (readonly/readwrite/
    # writeonly/consoleAdmin/diagnostics) are MinIO built-ins; the repo-defined
    # ones (terraform-sandbox-policy, otelcol-logs-policy) are what we judge.
    for pol in $("$MC" admin policy list "$ALIAS" 2>/dev/null); do
        case "$pol" in
            readonly|readwrite|writeonly|consoleAdmin|diagnostics) continue ;;
        esac
        printf '### policy: %s\n' "$pol"
        "$MC" admin policy info "$ALIAS" "$pol" 2>&1 || note "policy info $pol failed"
    done

    section "IAM: users + their attached policies (raw)"
    "$MC" admin user list "$ALIAS" 2>&1 || note "user list failed"
else
    note "no mcli/mc client available — falling back to on-host inventory (IAM is encrypted at rest; raw policy NOT recoverable on-host)"
    if reachable "$GROUP"; then
        section "on-host: bucket directories (data dir listing)"
        rssh "$GROUP" 'V=$(awk -F= "/MINIO_VOLUMES/{print \$2}" /etc/minio/minio.env 2>/dev/null); ls -la "$V" 2>/dev/null' 2>/dev/null \
          || note "data dir listing failed"
        section "on-host: IAM policy/user names (filenames only — contents encrypted)"
        rssh "$GROUP" 'V=$(awk -F= "/MINIO_VOLUMES/{print \$2}" /etc/minio/minio.env 2>/dev/null); \
          ls "$V"/.minio.sys/config/iam/policies "$V"/.minio.sys/config/iam/users 2>/dev/null' 2>/dev/null \
          || note "IAM name listing failed"
    else
        note "host $GROUP also unreachable over ssh — no dump"
    fi
fi
