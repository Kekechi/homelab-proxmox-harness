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

Runs every enabled component's Tier-1 verify in component manifest order
(MinIO → PKI → Nexus → DNS → log server → Splunk) and aggregates to a single
hard exit: `0` = all green, `1` = any component failed. A component whose
`services.<name>.enabled` is not true in `config/production.yml` is skipped as
off-by-design; a component that is enabled but ships no `verify.sh` is reported
as an explicit SKIP so the gap stays visible (Splunk is currently in this
category — see below). Driver: `scripts/verify/verify-all.sh`.

> **Scope note.** `verify-all` is discovery-driven: components are discovered
> from `components/` plus the private `components.local/` overlay, never
> hand-listed. Whatever enabled components exist on disk are what gets
> verified; the per-component targets below run the same scripts individually.

A green `verify-all` is the headline gate. Run the individual targets below only
to drill into a specific failure, or when you want to verify one component in
isolation.

### Per-component targets

Each `make verify-<component>` target runs that component's `verify.sh`, keyed
by the component directory name exactly (note the underscore in `log_server`).
Each queries the running daemons and exits `0`/`1`. All honor `ENV=production`.

| Target | What it checks |
|---|---|
| `make verify-pki` | step-ca issuing CA: liveness + served `/health` validated against the root CA cert + live provisioner list with ACME present. (The root CA is powered off by design and is not probed.) |
| `make verify-nexus` | Nexus: liveness + writable status + docker v2 + apt-proxy repo |
| `make verify-dns` | The whole DNS component, three sub-checks: PowerDNS Auth+Recursor (API health + zone + `dig`), DNSdist (liveness + `:53` resolution + webserver API), dns-collector (liveness + dnstap receiver bound) |
| `make verify-minio` | MinIO: liveness + `health/live` + `health/ready` |
| `make verify-log_server` | otelcol log server: liveness + `health_check` + syslog receivers bound + awss3 (MinIO) sink wired |

Splunk currently has no Tier-1 `verify.sh`; when enabled, `verify-all` reports
it as an explicit SKIP. Verify it through the deploy-sequence prerequisites
above and the Tier-2 sweep.

Example:

```bash
make verify-pki ENV=production
make verify-log_server ENV=production
```

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
`session/verification-findings.md`.

**Record-only.** The sweep never acts on a finding. Trust-model findings
(provisioner names/scopes/signing) are recorded only and are a `/design` item —
never remediated inside the sweep. Other-layer findings (DNS records, otelcol
routing, IAM breadth, Nexus repo/role hygiene) are likewise recorded only; they
may feed a later `/design` session or directly agreed follow-up work.

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
3. **Drill into the failure.** Re-run the specific failing per-component target
   with `ENV=production` (e.g. `make verify-nexus ENV=production`), read its
   output, fix the root cause, then re-run `make verify-all ENV=production`.
   Loop until green.
4. **Run the Tier-2 sweep:**
   ```
   /sanity-sweep
   ```
   Review `session/verification-findings.md`. Triage findings: a
   trust-model finding becomes a `/design` session; another-layer finding
   becomes a `/design` session or directly agreed follow-up work. **Do not
   remediate from inside the sweep.**
5. **Prod verified** when: `verify-all` is GREEN and the Tier-2 findings have
   been triaged (each either accepted or queued as a follow-up design/work
   item).
