#!/usr/bin/env bash
# =============================================================================
# gen-secrets.sh — fill missing loop secrets into .envrc (fill-if-empty)
#
# Generates strong values for the service passphrases / API keys the deploy
# needs, so an unattended destroy→rebuild loop never blocks on a human pasting
# secrets. Idempotent: an already-set, non-placeholder value is preserved.
#
# NOT generated here:
#   - PROXMOX_VE_API_TOKEN   operator-provided real token (error if missing)
#   - MINIO_ACCESS_KEY/SECRET_KEY  scoped IAM key, written by bootstrap-minio.sh
#                                  after the MinIO box is rebuilt
#
# Usage: bash scripts/loop/gen-secrets.sh [ENV]
# =============================================================================
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV="${1:-${ENV:-sandbox}}"
export ENV
# shellcheck source=lib.sh
source "${SELF_DIR}/lib.sh"

ENVRC="${REPO_ROOT}/.envrc"
UPSERT="${SELF_DIR}/envrc-upsert.py"
[[ -f "$ENVRC" ]] || die ".envrc not found — run 'make configure' first"

load_envrc

# A value needs (re)generation if unset, empty, or a CHANGE_ME-style placeholder.
needs() {
    local v="${!1:-}"
    [[ -z "$v" || "$v" == CHANGE_ME* || "$v" == changeme* || "$v" == "<"* ]]
}

set_if_missing() {
    local key="$1" gen="$2"
    if needs "$key"; then
        local val; val="$(eval "$gen")"
        python3 "$UPSERT" "$ENVRC" "$key" "$val"
        log "generated ${key}"
    else
        log "kept ${key} (already set)"
    fi
}

# Generators (hex avoids shell/CLI-hostile characters in downstream configs).
PW()    { openssl rand -hex 24; }       # 48-char passphrase
KEY()   { openssl rand -hex 32; }       # 64-char API key
UUID()  { python3 -c 'import uuid;print(uuid.uuid4())'; }

# --- hard requirement --------------------------------------------------------
if needs PROXMOX_VE_API_TOKEN; then
    die "PROXMOX_VE_API_TOKEN is not set in .envrc — operator must provide the real token; it cannot be generated."
fi

# --- MinIO admin (sets the rebuilt MinIO's root creds; ansible-minio reads them)
set_if_missing MINIO_ROOT_USER    'echo "minioadmin-$(openssl rand -hex 4)"'
set_if_missing MINIO_ROOT_PASSWORD PW

# --- step-ca passphrases -----------------------------------------------------
set_if_missing STEP_CA_ROOT_PASSWORD        PW
set_if_missing STEP_CA_ISSUING_PASSWORD     PW
set_if_missing STEP_CA_LXC_ROOT_PASSWORD    PW
set_if_missing STEP_CA_PROVISIONER_PASSWORD PW

# --- PowerDNS API keys -------------------------------------------------------
set_if_missing PDNS_AUTH_API_KEY     KEY
set_if_missing PDNS_RECURSOR_API_KEY KEY
set_if_missing PDNS_DNSDIST_API_KEY  KEY

# --- Nexus -------------------------------------------------------------------
set_if_missing NEXUS_ADMIN_PASSWORD  PW
set_if_missing NEXUS_READER_PASSWORD PW

# --- otelcol scoped MinIO key (awss3 log sink; IAM user provisioned by the role)
set_if_missing OTELCOL_MINIO_ACCESS_KEY 'echo "otelcol-$(openssl rand -hex 6)"'
set_if_missing OTELCOL_MINIO_SECRET_KEY PW

# --- Splunk (deprecation-planned; set so config generation does not break) ---
set_if_missing SPLUNK_ADMIN_PASSWORD PW
set_if_missing SPLUNK_HEC_TOKEN      UUID
set_if_missing SPLUNK_MCP_PASSWORD   PW

log "secret fill complete."
