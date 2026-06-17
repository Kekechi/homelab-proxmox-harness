#!/usr/bin/env bash
# =============================================================================
# run.sh — the destroy→rebuild verification loop (sandbox only)
#
# Drives one full from-scratch cycle. `set -e` makes it stop at the first
# failing phase — that captured failure IS the verification signal (e.g. the
# WS1 apt/TLS cold-start break). Re-run after a fix to confirm the loop gets
# further.
#
# Usage:
#   bash scripts/loop/run.sh [ENV] [--keep-minio] [--from PHASE] [--to PHASE]
#
#   --keep-minio   skip teardown+rebuild of MinIO/state (faster iteration when
#                  MinIO and Terraform state are not under test).
#   --from PHASE   start at PHASE (secrets|teardown|minio|configure|init|plan|
#                  apply|deploy|verify). Default: secrets.
#   --to PHASE     stop after PHASE. Default: verify.
#
# Phases:
#   secrets   fill any missing secrets into .envrc
#   teardown  API sweep of the sandbox pool (incl. MinIO unless --keep-minio)
#   minio     recreate MinIO LXC → ansible-minio → bootstrap scoped key to .envrc
#   configure regenerate all config artifacts
#   init      terraform init against the (empty) state bucket
#   plan      terraform plan (TF_INPUT=0 — fail, never prompt)
#   apply     terraform apply → creates the service LXCs/VMs
#   deploy    phased ansible: PKI → Nexus → DNS → log_server
#   verify    live evidence capture (reachability, cert issuers, apt health)
# =============================================================================
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEEP_MINIO=0
FROM="secrets"
TO="verify"
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-minio) KEEP_MINIO=1; shift ;;
        --from)       FROM="$2"; shift 2 ;;
        --to)         TO="$2"; shift 2 ;;
        *)            ARGS+=("$1"); shift ;;
    esac
done
ENV="${ARGS[0]:-${ENV:-sandbox}}"
export ENV
# shellcheck source=lib.sh
source "${SELF_DIR}/lib.sh"

[[ "$ENV" == "sandbox" ]] || die "the verification loop is sandbox-only (got ENV=$ENV)"

# Unattended terraform + ansible: never prompt, don't choke on rebuilt host keys.
export TF_INPUT=0
export ANSIBLE_HOST_KEY_CHECKING=False

PHASES=(secrets teardown minio configure init plan apply deploy verify)
phase_idx() { local p="$1" i; for i in "${!PHASES[@]}"; do [[ "${PHASES[$i]}" == "$p" ]] && { echo "$i"; return; }; done; echo -1; }
FROM_I=$(phase_idx "$FROM"); TO_I=$(phase_idx "$TO")
(( FROM_I >= 0 )) || die "unknown --from phase: $FROM"
(( TO_I   >= 0 )) || die "unknown --to phase: $TO"

active() { local i; i=$(phase_idx "$1"); (( i >= FROM_I && i <= TO_I )); }
banner() { printf '\n\033[1;36m========== PHASE: %s ==========\033[0m\n' "$1" >&2; }

cd "$REPO_ROOT"

# --- secrets -----------------------------------------------------------------
if active secrets; then
    banner secrets
    bash "${SELF_DIR}/gen-secrets.sh" "$ENV"
fi

# --- teardown ----------------------------------------------------------------
if active teardown; then
    banner teardown
    if [[ "$KEEP_MINIO" == 1 ]]; then
        bash "${SELF_DIR}/teardown.sh" "$ENV" --keep-minio
    else
        bash "${SELF_DIR}/teardown.sh" "$ENV"
    fi
    # Controller-local PKI staging must be wiped for a TRUE cold start: a stale
    # root_ca.crt would let `common` install trust for a CA that no longer
    # exists, masking the cold-start ordering bug the loop is meant to expose.
    if [[ -d "${REPO_ROOT}/.pki" ]]; then
        log "Wiping controller PKI staging (${REPO_ROOT}/.pki) for a clean cold start"
        rm -rf "${REPO_ROOT}/.pki"/*
    fi
fi

# --- minio -------------------------------------------------------------------
if active minio && [[ "$KEEP_MINIO" != 1 ]]; then
    banner minio
    bash "${SELF_DIR}/recreate-minio.sh" "$ENV"
    log "Provisioning MinIO via Ansible..."
    ( cd ansible && ansible-playbook -i inventory/ playbooks/minio-setup.yml --limit minio )
    log "Bootstrapping MinIO bucket + scoped IAM (writes scoped key to .envrc)..."
    bash "${REPO_ROOT}/scripts/bootstrap-minio.sh" "$ENV"
    # re-source so the freshly-written scoped key is in this shell for init
    load_envrc
fi

# --- configure ---------------------------------------------------------------
if active configure; then
    banner configure
    make configure ENV="$ENV"
fi

# --- init --------------------------------------------------------------------
if active init; then
    banner init
    load_envrc
    make init ENV="$ENV"
fi

# --- plan --------------------------------------------------------------------
if active plan; then
    banner plan
    make plan ENV="$ENV"
fi

# --- apply -------------------------------------------------------------------
if active apply; then
    banner apply
    make apply ENV="$ENV"
    log "Terraform apply complete — waiting for service hosts to become SSH-ready..."
    # (host reachability wait handled in deploy preflight)
fi

# --- deploy ------------------------------------------------------------------
# Phased deploy in dependency order. PLACEHOLDER ORDER — finalized after the
# Ansible audit. On a cold start this is where the WS1 apt/TLS break surfaces.
if active deploy; then
    banner deploy
    # The root-ca VM is created stopped (started=false / on_boot=false — offline
    # root CA). PKI deploy connects to it over SSH, so start it first. Idempotent.
    RCA_NODE="$(cfg services.pki.root_ca.node)"
    RCA_VMID="$(cfg services.pki.root_ca.vm_id)"
    RCA_IP="$(cfg services.pki.root_ca.ip)"; RCA_IP="${RCA_IP%%/*}"
    if [[ -n "$RCA_NODE" && -n "$RCA_VMID" ]]; then
        load_envrc; _pve_init
        st="$(pve_api GET "/nodes/${RCA_NODE}/qemu/${RCA_VMID}/status/current" \
              | python3 -c 'import sys,json;print(json.load(sys.stdin).get("data",{}).get("status",""))' 2>/dev/null || echo "")"
        if [[ "$st" != "running" ]]; then
            log "Starting offline root-ca VM ${RCA_VMID} on ${RCA_NODE}..."
            pve_api POST "/nodes/${RCA_NODE}/qemu/${RCA_VMID}/status/start" >/dev/null || warn "root-ca start call failed"
            for _ in $(seq 1 40); do
                ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                    -o ConnectTimeout=8 -o ProxyCommand="ncat --proxy squid-proxy:3128 --proxy-type http %h %p" \
                    "$(cfg services.pki.root_ca.ansible_user)@${RCA_IP}" true 2>/dev/null && break
                sleep 8
            done
        fi
    fi
    cd ansible
    log "Phase: PKI";        ansible-playbook -i inventory/ playbooks/pki-setup.yml
    log "Phase: Nexus";      ansible-playbook -i inventory/ playbooks/nexus-setup.yml --limit nexus
    log "Phase: DNS auth";   ansible-playbook -i inventory/ playbooks/dns-setup.yml
    log "Phase: DNS records";ansible-playbook -i inventory/ playbooks/dns-records.yml
    log "Phase: DNS dist";   ansible-playbook -i inventory/ playbooks/dns-dist-setup.yml
    cd "$REPO_ROOT"
fi

# --- verify ------------------------------------------------------------------
if active verify; then
    banner verify
    bash "${SELF_DIR}/verify.sh" "$ENV" || warn "verify reported issues (see above)"
fi

log "Loop run complete (phases ${FROM}..${TO})."
