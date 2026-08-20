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
#   --include-vms  destroy qemu VMs too (root-ca, splunk) in teardown — the TRUE
#                  cold start from nothing. Without it, kept VMs + a wiped state
#                  (MinIO recreate) collide at apply. Forwarded to teardown.sh.
#   --from PHASE   start at PHASE (secrets|teardown|minio|configure|init|plan|
#                  apply|deploy|gate|verify). Default: secrets.
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
#   gate      HARD Tier-1 regression gate: `make verify-all` (behavioral, queries
#             the live daemons). Non-zero HALTS the loop — this is the only phase
#             that gates on service-correctness, not just absence of a failure.
#   verify    live evidence capture (reachability, cert issuers, apt health)
#
# Note: `gate` is a deliberate behavior change vs. the evidence-only `verify`
# phase (which always exits 0). `gate` stops the loop on a failed/incomplete
# service so a regression (e.g. a skipped role) cannot pass silently.
# =============================================================================
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEEP_MINIO=0
INCLUDE_VMS=0
FROM="secrets"
TO="verify"
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-minio)  KEEP_MINIO=1; shift ;;
        --include-vms) INCLUDE_VMS=1; shift ;;
        --from)        FROM="$2"; shift 2 ;;
        --to)          TO="$2"; shift 2 ;;
        *)             ARGS+=("$1"); shift ;;
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

PHASES=(secrets teardown minio configure init plan apply deploy gate verify)
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
    TD_ARGS=("$ENV")
    [[ "$KEEP_MINIO"  == 1 ]] && TD_ARGS+=(--keep-minio)
    [[ "$INCLUDE_VMS" == 1 ]] && TD_ARGS+=(--include-vms)
    bash "${SELF_DIR}/teardown.sh" "${TD_ARGS[@]}"
    # Controller-local PKI staging must be wiped for a TRUE cold start: a stale
    # root_ca.crt would let `common` install trust for a CA that no longer
    # exists, masking the cold-start ordering bug the loop is meant to expose.
    if [[ -d "${REPO_ROOT}/.pki" ]]; then
        log "Wiping controller PKI staging (${REPO_ROOT}/.pki) for a clean cold start"
        rm -rf "${REPO_ROOT}/.pki"/*
    fi
    # Rebuilt hosts reuse their IPs but present FRESH SSH host keys. ansible.cfg
    # uses StrictHostKeyChecking=accept-new, which accepts UNKNOWN hosts but
    # REFUSES a host whose key CHANGED — so a stale known_hosts entry from the
    # prior build makes the very first ansible-playbook fail UNREACHABLE
    # ("REMOTE HOST IDENTIFICATION HAS CHANGED"). The raw-ssh readiness waits in
    # this loop dodge it with UserKnownHostsFile=/dev/null, but ansible uses the
    # real known_hosts. Purge the sandbox host keys here (same cold-start hygiene
    # as the .pki wipe) so the rebuilt hosts re-key cleanly on first contact.
    if [[ -f "${HOME}/.ssh/known_hosts" ]]; then
        log "Purging stale known_hosts entries for sandbox service IPs (rebuilt hosts re-key)"
        for _svc_ip in \
            "$(cfg services.minio.ip)" \
            "$(cfg services.pki.root_ca.ip)" \
            "$(cfg services.pki.issuing_ca.ip)" \
            "$(cfg services.dns.auth.ip)" \
            "$(cfg services.dns.dist.ip)" \
            "$(cfg services.nexus.ip)" \
            "$(cfg services.log_server.ip)" \
            "$(cfg services.splunk.ip)"; do
            _svc_ip="${_svc_ip%%/*}"   # strip any /prefix
            [[ -n "$_svc_ip" ]] || continue
            ssh-keygen -R "$_svc_ip" >/dev/null 2>&1 || true
        done
    fi
fi

# --- minio -------------------------------------------------------------------
if active minio && [[ "$KEEP_MINIO" != 1 ]]; then
    banner minio
    bash "${SELF_DIR}/recreate-minio.sh" "$ENV"
    log "Provisioning MinIO via Ansible..."
    # Cold rebuild: Nexus does not exist yet, so base packages MUST fall back to
    # upstream. nexus_fallback defaults to 'fail' (see apt-fallback-policy.md);
    # override to 'upstream' here so this bootstrap deploy does not abort.
    ( cd ansible && ansible-playbook -i inventory/ ../components/minio/playbook.yml --limit minio -e nexus_fallback=upstream )
    log "Bootstrapping MinIO bucket + scoped IAM (writes scoped key to .envrc)..."
    bash "${REPO_ROOT}/components/minio/bootstrap.sh" "$ENV"
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
            # Wait on the SAME real signal as the MinIO probe: N CONSECUTIVE full
            # SSH handshakes, not one lucky success during the freshly-booted
            # path's lossy settling window (WS1/WS2 characterised this on the MinIO
            # LXC; a fresh qemu boot can settle on a similar timer). The first
            # ansible PKI play connects into this box immediately after, so a false
            # "ready" here would make that play fail UNREACHABLE on a half-settled
            # path. Deadline is a safety net (10 min); readiness is the signal.
            RCA_USER="$(cfg services.pki.root_ca.ansible_user)"; : "${RCA_USER:=root}"
            rca_deadline=$(( $(date +%s) + 600 )); rca_consec=0
            until (( $(date +%s) >= rca_deadline )); do
                if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                       -o ConnectTimeout=8 -o ProxyCommand="ncat --proxy squid-proxy:3128 --proxy-type http %h %p" \
                       "${RCA_USER}@${RCA_IP}" true 2>/dev/null; then
                    rca_consec=$(( rca_consec + 1 ))
                    log "  root-ca handshake ok (${rca_consec}/3)"
                    (( rca_consec >= 3 )) && { log "root-ca VM ${RCA_VMID} reachable."; break; }
                    sleep 3
                else
                    (( rca_consec > 0 )) && warn "  root-ca handshake streak broken — path still settling"
                    rca_consec=0
                    sleep 8
                fi
            done
            (( rca_consec >= 3 )) || warn "root-ca VM ${RCA_VMID} not confirmed reachable within 10 min — PKI play may fail UNREACHABLE"
        fi
    fi
    cd ansible
    # Cold rebuild bootstrap: Nexus does not exist until its own phase below, so
    # every phase that runs `common` (base apt) or fetches a raw artifact before
    # Nexus is up MUST fall back to upstream. nexus_fallback defaults to 'fail'
    # (the fail-safe steady-state policy, see docs/design/apt-fallback-policy.md);
    # override to 'upstream' for the whole cold-rebuild deploy so it does not
    # abort at the PKI phase. Day-2 deploys keep the 'fail' default.
    APT_FALLBACK="-e nexus_fallback=upstream"
    log "Phase: PKI";        ansible-playbook -i inventory/ ../components/pki/playbook.yml $APT_FALLBACK
    log "Phase: Nexus";      ansible-playbook -i inventory/ ../components/nexus/playbook.yml --limit nexus $APT_FALLBACK
    log "Phase: DNS";        ansible-playbook -i inventory/ ../components/dns/playbook.yml $APT_FALLBACK
    log "Phase: log-server"; ansible-playbook -i inventory/ ../components/log_server/playbook.yml $APT_FALLBACK
    cd "$REPO_ROOT"
fi

# --- gate --------------------------------------------------------------------
# HARD Tier-1 regression gate. `make verify-all` runs the per-service behavioral
# verifies (scripts/verify/), each querying the live daemon, aggregating to a
# single exit 0 (all green) / 1 (any service down or incompletely deployed).
#
# Unlike the evidence-only `verify` phase below, this one GATES: a non-zero exit
# (set -e) halts the loop here so a regression — e.g. a skipped/failed role that
# left a service down — cannot slip past into a "successful" run.
if active gate; then
    banner gate
    make verify-all ENV="$ENV"
fi

# --- verify ------------------------------------------------------------------
if active verify; then
    banner verify
    bash "${SELF_DIR}/verify.sh" "$ENV" || warn "verify reported issues (see above)"
fi

log "Loop run complete (phases ${FROM}..${TO})."
