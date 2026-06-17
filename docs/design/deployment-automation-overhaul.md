# Deployment Automation Overhaul — Session Brief

Status: planning complete, ready for execution
Scope: autonomous long-running session to fix the broken from-scratch deployment path and reduce maintenance friction.

This is a work plan for an autonomous session, not a design record. It assumes the
reader is the agent executing it. Findings cite `file:line` in this repo; no
environment specifics (IPs, domain, VLANs) appear here — resolve those from
`config/<env>.yml` / `.envrc` at runtime.

---

## 1. Operating model

- **Autonomous.** Drive each workstream end-to-end. Existing skills (`/ansible-deploy`,
  `/tf-deploy`, `/polish`) are *reference* for method, not gospel — their human-approval
  gates do not apply. Verify on real systems; do not proceed on unverified hypotheses.
- **Subagent architecture.** Main thread = task management. Push all noisy work (long file
  reads, command output, role audits) into **one layer** of subagents that return
  conclusions, not dumps. Use Workflow for genuine fan-out. No deep nesting (unverified;
  one layer already buys context-leanness).
- **Verification is live.** The destroy→rebuild loop is the harness. Code reading reinforces
  hypotheses; the real system confirms them. Capture actual errors (apt failure text, cert
  issuer) rather than reasoning from general knowledge.

### Safety boundary (what stays vs. relaxes)

- **Environment-enforced (no effort needed):** production is unreachable — no prod token in
  the container, Squid blocks prod IPs, prod state bucket needs separate creds. Accidental
  prod actions cannot even start.
- **Discipline-required (the only live rails):**
  - **No `git push`.** Commit freely at checkpoints (each verified fix = a commit) for clean
    review + rollback; the operator reviews history and pushes. (Recommended: enforce with a
    `Bash(git push:*)` deny rule.)
  - **Public-repo hygiene in every commit:** never commit `.envrc`, `config/*.yml`, secrets,
    or topology (IPs, VLAN IDs, internal hostnames, domain, product names). Mostly covered by
    `.gitignore` + lint hooks; the live part is the doc-topology check on authored docs.
  - **Sandbox state-bucket integrity:** never delete the bucket itself (objects are fine).
- **Relaxed (authorized):** sandbox destroy/rebuild (incl. MinIO), editing `.envrc` /
  `config/*.yml`, skipping skill approval gates.

---

## 2. Prerequisites (operator, before the session)

1. **Squid resilient resolver — REQUIRED, or the session bricks itself.**
   Squid's sole resolver is the internal DNS box (`squid.conf.local`, single
   `dns_nameservers` entry). The loop destroys that box, so during the rebuild gap Squid
   cannot resolve anything — including the agent's own API through the proxy — and the
   session deadlocks (it needs DNS to issue the apply that would restore DNS).
   **Fix:** add a public DNS secondary (internal first, public second) to `squid.conf.local`,
   then `make build` + reopen. Verify failover behavior live (kill internal DNS, confirm
   external names still resolve at acceptable latency) before trusting an unattended run.
   - `.devcontainer` edits are operator-directed; the agent may prepare the `squid.conf.local`
     change but the operator runs the rebuild.
2. **MinIO LXC + Proxmox API token** exist (one-time; not re-created per loop unless testing
   the MinIO bootstrap script itself).
3. **Network bridge** for the sandbox VLAN exists (bridge creation needs `Sys.Modify`, which
   the token lacks; recreating only LXCs is fine).

---

## 3. Loop architecture (the verification harness)

Nothing is preserved — full from-scratch each cycle:

```
1. Teardown:   PVE-API sweep of the sandbox pool — delete all members incl. MinIO,
               scoped to the sandbox pool ONLY. (Simpler than terraform-destroy: teardown
               is not the thing under test, and it sidesteps "state lives in the thing
               you're destroying.")
2. MinIO:      recreate the MinIO LXC via PVE API + cloud-init key injection (NOT the legacy
               GUI/pct-exec procedure) so it boots SSH-ready → ansible-minio →
               bootstrap-minio.sh (bucket + IAM, writes scoped key into .envrc).
3. State:      fresh terraform init (empty bucket) → plan -input=false → apply.
4. Deploy:     run the phased deploy (PKI → Nexus → DNS → services) — THIS is what's tested.
5. Verify:     capture live evidence (apt errors, cert issuers, systemctl/journalctl).
```

Key facts (verified):
- MinIO is **outside the Terraform graph** (`generate-configs.py:472`) — recreation is a
  bootstrap script, not `terraform apply` (bootstrap paradox: TF state lives in MinIO).
- The token **can** create LXCs via the API alone (`TerraformSandbox` has `VM.Allocate` +
  storage/SDN; repo creates LXCs with no `ssh {}` block). Avoid snippet/file-upload/idmap
  features (those would need node SSH).
- Loop **must keep every sandbox VM IP inside the already-allowed Squid CIDR** so no rebuild
  is ever needed mid-loop.

---

## 4. Workstreams (dependency order)

### WS0 — Loop driver + mechanical prereq fixes (do first; unblocks everything)

- MinIO LXC bootstrap script: create via API + cloud-init; replaces manual GUI/`pct exec`.
  Update the stale `docs/guides/minio-setup.md`.
- `bootstrap-minio.sh`: write the scoped key into `.envrc` instead of echoing it.
- Destroy path: use plan-destroy form or API sweep — `make destroy` (`Makefile:91`) uses bare
  `terraform destroy`, which `terraform-guard.sh:38` blocks; guard's suggested replacement
  also drifts on varfile name (`D7`).
- `make plan/apply` should depend on `make configure` (`B6`); `make init` should too, or assert
  `.env.mk` ENV matches `$(ENV)` to avoid wrong-bucket init (`D6`).
- Secret injection: generate random/derivable secrets (Nexus, PDNS, step-ca passphrases via
  `openssl rand`/uuid) straight into `.envrc`. Local, uncommitted test `config/sandbox.yml`
  with all `network:` set + `-input=false` to avoid the interactive-prompt gotcha (`B-network`,
  `variables.tf:242` `log_server_bridge` has no default).

### WS1 — apt/TLS cold-start bootstrap (the core breakage)

Root cause is deeper than handler-timing — it's a **cold-start ordering inversion**:
- `B2`: `common` installs CA trust only `when` the controller already has `root_ca.crt`, but
  `step_ca_root` produces that file *later in the same run* → on cold start trust is skipped
  while `common`'s HTTPS `apt update` (`common/tasks/main.yml:53`) still runs.
- `B3`: `step_client` never runs `step ca bootstrap`; issuance works only because `common`
  happened to install the root cert. If B2 skipped it, every `step ca certificate --root …`
  fails.
- `B4`: `common` deletes default apt sources for non-Nexus hosts with no fallback if Nexus
  isn't up — hard Nexus-first dependency, unguarded.
- `B1`: `step_ca_issuing` writes the x509 allow-policy only `when ca.json` already exists, but
  stats it *before* `step ca init` → policy never applied on first run.
- `D1`: standalone `*-setup.yml` run `common` but not PKI → `tls.yml` "CA unreachable → skip"
  guards make services come up plaintext and report success. No master ordered playbook.
- `D2`: Nexus nginx vhost references certs before they're issued; if CA down, nginx
  start/reload fails — cascades to every apt client (Nexus is the proxy).
- Also check `L9` (common apt rewrite is Debian-only; Ubuntu hosts bypass Nexus), `L3`/`L4`
  (step-ca provisioner naming / implicit config path — verify live), `L5` (root CA **private
  key** transits `/workspace/.pki/` — public repo; verify gitignored + add assertion).

**Fix layer:** establish CA trust + base-repo reachability as an explicit early bootstrap that
does not depend on Nexus-over-HTTPS, before any `apt update`; add `step ca bootstrap` to
clients; guard source deletion; fix the policy-on-first-run stat. Verify with the loop:
captured apt error + cert issuer on a fresh host.

### WS2 — Cert-renewal resilience

- `L1`: no re-enroll fallback when a cert is fully expired (all three renewers use
  `step ca renew`, which needs a still-valid cert). 24h cert + short timer, but a long outage
  past `notAfter` is unrecoverable without re-enroll. `maxTLSCertDuration` never templated →
  certs sit at the 24h max.
- `D3`: MinIO renewer has no reload hook (diverges from nexus/splunk designs) — verify MinIO
  actually serves a rotated cert.
- **Deliverables (sized after verifying actual margins):** self-heal re-enroll on expiry;
  emit renewal failure to the **syslog/journald layer** (SIEM-agnostic — see Splunk note);
  consider widening renewal headroom. No new Splunk coupling.

### WS3 — generate-configs.py modularization + progressive disclosure (broader)

Lowest risk; the loop is its regression test. Audience = the agent (not human readers).

- **Module boundary (decided):** per-output-artifact + pull validation/helpers into named
  modules. `scripts/genconfig/{main,config,helpers,validation}.py` +
  `emit/{tfvars,inventory,allowed_cidrs,envrc,env_mk,pki_group_vars}.py`. Per-domain rejected:
  `gen_inventory` has cross-service derivations (log_server reads minio; dns_dist reads
  dns_auth + log_server) that a service split would shatter.
- **Progressive disclosure mechanism:** co-located `CLAUDE.md` (harness auto-loads by
  directory proximity). Top-level `scripts/genconfig/CLAUDE.md` = task→module routing table +
  pointer to `.claude/rules/config-management.md` (don't duplicate). `emit/CLAUDE.md` = shared
  emitter contract (DO-NOT-EDIT header, byte-stability rule). Per-artifact docs = contract +
  cross-service reads to watch. **Apply the same pattern to other long artifacts** (the
  `common` role, long roles, dense docs) — this is a broader workstream, not just the generator.
- **Safety net:** golden-output test — but build it (`L11`: current `test-generator.py` skips
  the `.envrc` merge + branchy emitters). Test each `gen_*` against a fixture config dict
  (not a committed `config/*.yml`); this sidesteps the `.envrc` smart-merge nondeterminism.
- **Generator bugs to fix in passing:** `L6` (`ssh_public_key ""` → `[""]`; emit `null` via
  `_hcl_str`), `L8` (`domain_name=null` → malformed output; omit line when empty), `L7`
  (`clone_template_id` dead config), `D5` (syslog ports duplicated across 3 roles — emit from
  one field), `B8` (`make configure` hard-exits if log_server present w/o MinIO IP).
- Document the "add a new config field / new service" procedure (Case A / Case B) in the
  routing doc.

### Splunk deprecation track (parallel, low-priority cleanup — do NOT invest in Splunk)

Splunk is deprecation-planned (too heavy; whole node). Do not build new Splunk coupling.
- `B7`/`B8`/`B9`: log_server/otelcol is hard-coupled to a fully-configured Splunk (unconditional
  HEC asserts; configure hard-exit; needs MinIO **admin** creds the container lacks). Decouple
  the splunk_hec exporter behind a generator-emitted flag; the real sink is the MinIO `awss3`
  exporter. Split bucket provisioning into an operator one-time bootstrap.
- `B5`: otelcol DEB fetched from github directly — move to a Nexus raw repo (mirror
  `dns_collector` pattern) so log_server installs on locked-down hosts.
- `D4` (HEC plaintext), Splunk index gap (`index=main` vs `homelab-logs` never created),
  MCP token steps — LOW priority; park.

### Latent / cleanup (note, fix opportunistically)

`L2` (setcap lost on apt upgrade — step-ca, dnsdist), `L10` (dns-collector tarball casing),
`L12` (unused `proxmox-network` module), `L4` (step-ca implicit config path).

---

## 5. Sequencing rationale

WS0 first (the loop is the harness everything else is verified against) → WS1 (the loop reaches
the apt/TLS failure; that captured error IS the live verification; fix it; loop now gets past) →
WS2 (verified across rebuilt hosts) → WS3 (lowest risk; loop is its golden regression test).
Splunk-decoupling and cleanup interleave where they unblock the loop (B5/B7/B8 block log_server).

---

## 6. Open items

- Whether to enforce "no push" via a `Bash(git push:*)` deny rule (recommended) vs. instruction.
- Squid resilient-resolver approach: public secondary (simplest) vs. static `hosts_file` +
  public resolver (most decoupled). Verify failover before relying on it.
