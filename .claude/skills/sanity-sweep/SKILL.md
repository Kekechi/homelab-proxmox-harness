---
name: sanity-sweep
description: Tier-2 agent sanity sweep over the deployed services. Runs the read-only Tier-2 collectors, reads the raw behavioral-state dumps, and judges per service "is this working as intended? any smell, misconfig, confusing naming, or over-broad scope?" — writing findings to .claude/session/verification-findings.md. RECORD ONLY; never acts on any finding, and NEVER touches the trust model (provisioner names/scopes/signing) — that is a /design item.
disable-model-invocation: false
---

# Skill: Tier-2 Agent Sanity Sweep

This is the **fuzzy, on-demand** complement to the Tier-1 machine gate
(`scripts/verify/`, `make verify-all`). Tier 1 makes hard, pre-written
behavioral assertions (`exit 0/1`). Tier 2 catches what you *cannot* write an
assertion for in advance: "this provisioner name is confusing", "this scope is
broader than it needs to be", "this NS record points at an obviously-invalid
host". Those are **judgments**, made by an agent reading the *raw* state.

The collectors (`scripts/collect/`) only **dump** raw behavioral state — they
make no pass/fail call. This skill drives the agent to read those dumps and
**judge**, then record findings. Nothing here is a gate; nothing here acts.

## Hard rules (read before running)

- **READ-ONLY.** Run only the Tier-2 collectors and read their dumps. Do NOT
  modify any service, config, cert, or trust-model artifact. Do NOT restart or
  stop anything.
- **RECORD FINDINGS ONLY — act on NONE of them.** This skill produces a findings
  document. It does not fix, reconfigure, or remediate.
- **NEVER act on a trust-model finding.** Any finding about PKI provisioner
  names, scopes, claims, or signing (e.g. a confusingly-named provisioner, an
  over-broad wildcard issuance scope) is recorded **only** — implementing it is
  a `/design` item and is **forbidden here**. If a finding implies a trust-model
  change, write it down and move on; do not propose or apply a change.
- Findings about other layers (DNS records, otelcol routing, IAM policy breadth,
  Nexus repo/role hygiene) are likewise **recorded only** in this skill — they
  may feed a later plan/design, but this sweep does not act.

## Instructions

1. **Run the collectors.** From the repo root:

   ```bash
   bash scripts/collect/collect-all.sh
   ```

   This writes per-component raw dumps under
   `.claude/session/collect-dump/<UTC-timestamp>/` — collectors are discovered
   from `components/*/collect.sh` (+ `components.local/`), so enabled private
   components are swept too — and echoes them to stdout. Disabled components are
   skipped (e.g. Splunk when off by design in sandbox). To enrich the Nexus dump with privileged sections
   (roles/privileges/users), export `NEXUS_ADMIN_PASSWORD` first; without it,
   those sections are noted as gaps and the public repo list is still dumped.
   The MinIO collector queries via the local `mcli` admin alias
   (`homelab-minio-sandbox` by default) because `mc` is not on the MinIO host
   and IAM is encrypted at rest.

2. **Read each dump and judge.** For every service, read its `<svc>.txt` and ask:
   - Is the service **working as intended** (does the live state match what the
     service is supposed to be doing)?
   - Any **smell**: confusing or misleading naming; an over-broad scope/grant
     (wildcard issuance, an IAM policy or role wider than its job needs); a
     placeholder/invalid value that escaped into live config; a pipeline that
     routes somewhere unexpected; a config-vs-behavior divergence.
   - For each, record: service, what was observed (cite the dump), why it is a
     smell, severity (info / smell / misconfig), and — explicitly — whether it
     is a **trust-model** item (and therefore `/design`-only, not actionable
     here).

3. **Confirm the known plant is caught (self-check of the sweep).** The issuing
   CA currently carries a deliberate plant that this sweep MUST surface:
   - a confusingly-named provisioner pair — a **JWK** provisioner named `acme`
     alongside an **ACME** provisioner named `acme-1` (the name `acme` does not
     match its type), and
   - an **over-broad wildcard issuance scope** — authority-level
     `x509.allow.dns: ["*.<domain>"]` with `allowWildcardNames: true`, so any
     provisioner can mint a cert for the whole domain wildcard.

   If the pki component's collector dump (`components/pki/collect.sh`) no longer
   shows an `acme`/ACME provisioner, **STOP and report** (the plant is gone — unexpected; the sweep's
   own validity is in question). Both halves of the plant are **trust-model**
   findings → record them, do **not** act.

4. **Write the findings.** Write `.claude/session/verification-findings.md` with:
   - a header (UTC timestamp, ENV, dump dir path, collector commit if known);
   - one section per service with its findings (or "no smell observed");
   - for every finding: observation (with dump citation), why-it-smells,
     severity, and the **actionable-here? yes/no** flag (trust-model ⇒ no);
   - a closing "known-plant self-check" line stating whether the `acme`
     naming + wildcard-scope plant was surfaced (the sweep's machine-checkable
     success criterion).

5. **Report, do not act.** Present a short summary (count of findings by
   severity, plus the plant self-check result). Do **not** open a plan, edit a
   config, or touch any service. If the operator wants to act on a finding, that
   is a separate `/design` session (trust-model) or a separately agreed change
   (other layers).

## Output

- `.claude/session/verification-findings.md` — the recorded findings (the
  operator's async audit surface; uncommitted by default).
- A console summary: findings-by-severity + the known-plant self-check verdict.

## Cadence

On-demand for now (run this skill when you want a semantic read of the live
deployment). Whether a sampled version also runs inside the rebuild loop is
deferred until Tier 1 + this sweep are both in place.
