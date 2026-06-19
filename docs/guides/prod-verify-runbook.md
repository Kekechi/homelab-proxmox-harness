# Production Verification Runbook

Operator runbook for verifying a **production** environment after a deploy.
This is the path from "deploy done" → "prod verified". It assumes the production
deploy sequence has completed (see `docs/guides/deployment-guide.md` for the
sandbox phase walkthrough; the production sequence mirrors it with operator-side
Terraform apply).

Verification has two tiers:

- **Tier 1 — machine gate.** Pre-written behavioral assertions that query the
  live daemon (not its config) and exit hard `0`/`1`. Run via `make verify-*`.
  This is the gate: green means every checked service is behaviorally up.
- **Tier 2 — agent sanity sweep.** A fuzzy, on-demand semantic read of the live
  deployment that catches what you cannot assert in advance (confusing naming,
  over-broad scope, a placeholder that escaped into live config). Run via
  `/sanity-sweep`. **Record-only — it never acts.**

All host/IP/domain specifics are resolved at runtime from `config/production.yml`
and the generated production inventory. This runbook refers to them generically.

> **Environment selection.** Every Tier-1 target honors `ENV`. For production,
> append `ENV=production` to each command (e.g. `make verify-all ENV=production`).
> The default is `sandbox` — do not omit `ENV` when verifying production.

---

## Prerequisite — confirm the deploy sequence completed

The production deploy brings up log-server and Splunk on top of an already-
deployed MinIO, PKI, DNS, and Nexus. Two steps in that sequence are easy to miss
and will make verification fail in confusing ways if skipped — confirm them
before you start verifying:

- **Step 7b — TLS + FQDN on the Splunk management port.** `tls: true` and a
  matching `fqdn:` must be set under the Splunk service in `config/production.yml`
  *before* `make configure`. This drives a step-ca ACME certificate (with a
  renewal timer) onto the management port (8089), which the MCP HTTPS endpoint
  requires. If TLS/FQDN was added after `make configure`, you must re-run
  `make configure ENV=production` and re-run the Splunk playbook before this
  cert exists.
- **Step 7c — create the `homelab-logs` index BEFORE enabling HEC.** The index
  must exist before any HEC traffic lands, or events are silently dropped. If
  log-server is forwarding to Splunk but no events appear, an absent index is the
  first thing to check.

If either is in doubt, resolve it before reading any verify result as
authoritative.

---

## Tier 1 — machine gate

### One-shot gate: `make verify-all`

```bash
make verify-all ENV=production
```

Runs every per-service Tier-1 verify in trust/dependency order (CA → repo →
resolver chain → storage → telemetry) and aggregates to a single hard exit:
`0` = all green, `1` = any service failed. Splunk is verified only when
`services.splunk.enabled` is true in `config/production.yml`; it is skipped
gracefully otherwise. Driver: `scripts/verify/verify-all.sh`.

> **Scope note.** `verify-all` runs the seven per-service verifies below
> (issuing-ca, nexus, dns-auth, dnsdist, dns-collector, minio, log-server) plus
> Splunk when enabled. It does **not** run `verify-isolation` — that is a
> dev-container network check and is run separately (see below).

A green `verify-all` is the headline gate. Run the individual targets below only
to drill into a specific failure, or when you want to verify one service in
isolation.

### Per-service targets

Each target queries the running daemon and exits `0`/`1`. All honor
`ENV=production`.

| Target | What it checks |
|---|---|
| `make verify-issuing-ca` | step-ca issuing CA: liveness + served `/health` + provisioner list |
| `make verify-nexus` | Nexus: liveness + writable status + docker v2 + apt-proxy repo |
| `make verify-dns-auth` | PowerDNS Auth+Recursor: API health + zone + `dig` resolution |
| `make verify-dnsdist` | DNSdist: liveness + `:53` resolution + webserver API |
| `make verify-dns-collector` | dns-collector: liveness + dnstap receiver bound |
| `make verify-minio` | MinIO: liveness + `health/live` + `health/ready` |
| `make verify-log-server` | otelcol log server: liveness + `health_check` + syslog receivers + awss3 sink |

Example:

```bash
make verify-issuing-ca ENV=production
make verify-log-server ENV=production
```

### Network isolation: `make verify-isolation`

```bash
make verify-isolation
```

Runs the dev-container network isolation verification
(`scripts/verify-isolation.sh`): confirms internal endpoints are reachable and
that direct internet egress is blocked where it should be. This is a separate
check from the per-service behavioral gate and is **not** part of `verify-all`.

---

## Tier 2 — agent sanity sweep (`/sanity-sweep`)

Once Tier 1 is green, run the Tier-2 sweep for a semantic read of the live
deployment:

```
/sanity-sweep
```

This runs the read-only Tier-2 collectors, reads the raw behavioral-state dumps,
and judges per service: *is this working as intended? any smell, misconfig,
confusing naming, or over-broad scope?* Findings are written to
`.claude/session/verification-findings.md`.

**Record-only.** The sweep never acts on a finding. Trust-model findings
(provisioner names/scopes/signing) are recorded only and are a `/design` item —
never remediated inside the sweep. Other-layer findings (DNS records, otelcol
routing, IAM breadth, Nexus repo/role hygiene) are likewise recorded only; they
may feed a later `/infra-plan` or `/design` session.

> To enrich the Nexus dump with privileged sections (roles/privileges/users),
> export `NEXUS_ADMIN_PASSWORD` before running.

---

## Clean operator path: deploy done → prod verified

1. **Confirm deploy prerequisites** — Step 7b (Splunk TLS + FQDN cert on 8089)
   and Step 7c (`homelab-logs` index exists before HEC). See above.
2. **Run the machine gate:**
   ```bash
   make verify-all ENV=production
   ```
   - **GREEN** → proceed to step 4.
   - **RED** → go to step 3.
3. **Drill into the failure.** Re-run the specific failing per-service target
   with `ENV=production` (e.g. `make verify-nexus ENV=production`), read its
   output, fix the root cause, then re-run `make verify-all ENV=production`.
   Loop until green.
4. **Run the network isolation check:**
   ```bash
   make verify-isolation
   ```
5. **Run the Tier-2 sweep:**
   ```
   /sanity-sweep
   ```
   Review `.claude/session/verification-findings.md`. Triage findings: a
   trust-model finding becomes a `/design` session; another-layer finding becomes
   an `/infra-plan` session. **Do not remediate from inside the sweep.**
6. **Prod verified** when: `verify-all` is GREEN, `verify-isolation` passes, and
   the Tier-2 findings have been triaged (each either accepted or queued as a
   follow-up plan/design item).
