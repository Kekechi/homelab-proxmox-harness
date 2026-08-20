# Threat Model

This document defines what the isolation architecture protects against and what it does
not, under the **controller-host model**: the agent runs on a dedicated host with only
sandbox-scoped credentials, and enforcement is IAM-first. (The earlier containerized
model with a deny-by-default forward proxy is retired; this document describes what
replaced it, honestly — including where the old model was stronger.)

## What This Protects Against

### Claude Code reaching production Proxmox resources

**Mechanism:** IAM, two mutually reinforcing facts.

1. Claude's token (`terraform@pve!claude-sandbox`) has ACL only on `/pool/sandbox` —
   the Proxmox API returns 403 for any resource outside the sandbox pool.
2. The operator token (`operator-production`) is never present on the controller host,
   so a production apply fails at authentication before touching anything.

Network segmentation backs this up: the operator places the controller host so that
production segments are not routable from it.

### Claude Code reading or corrupting production Terraform state

**Mechanism:** MinIO IAM plus absence. Claude's MinIO key is bound to a policy scoped
to the `tfstate-sandbox` bucket on the sandbox MinIO instance. The production MinIO
instance is on a segment the controller host cannot reach, and its credentials never
exist on the host.

### Claude Code escalating Proxmox privileges

**Mechanism:** `privsep=1` on the token — it cannot exceed the `terraform@pve` user's
privileges. The `TerraformSandbox` role excludes `Permissions.Modify` and
`User.Modify`, so the agent cannot create tokens, modify roles, or grant itself
broader access; `Pool.Allocate` is excluded, so it cannot move resources between pools.

## What This Does NOT Protect Against

### Arbitrary internet access

The retired proxy model denied all egress by default; the controller-host model does
not. The agent has the host's own internet egress. This is an **accepted trade-off**:
the harness relies on Claude Code's permission layer, the operator's review of session
activity, and the absence of production credentials — not on network egress control.

### Exfiltration through git history

The agent can commit anything to the local repo. Mitigations: `git push` is denied to
the agent's shell; the operator reviews history before pushing; rules require
intent-level docs (no internal IPs/hostnames/domains) and forbid committing secrets.
A staged-secrets git pre-commit hook is a planned reinstatement (deferred — see the
harness-rebuild design record). **Residual risk:** an unreviewed push publishes
whatever was committed.

### SSH within the sandbox segment

There is no per-destination SSH ACL anymore. Raw `ssh`/`scp` are denied at the agent's
permission layer (the `sandbox-ssh` alias is the deliberate pass-through), and the host
routes only to sandbox segments — but within the sandbox, SSH reach is uniform. The
sandbox is built to be expendable; this is accepted.

### State corruption from concurrent sandbox applies

MinIO's S3 backend has no real state locking (no DynamoDB equivalent). Concurrent
applies can corrupt state. **Mitigation:** plan-file workflow (short apply window) and
operator coordination. Recovery: MinIO object versioning + the destroy→rebuild loop.

### Secrets on the controller host

The agent can read `.envrc` — this is by design (it needs the sandbox credentials to
work). The trust boundary is that *only sandbox-scoped* secrets exist there. Anything
placed on the controller host must be assumed readable by the agent.

### Supply chain attacks via providers or collections

Without an egress allowlist, this surface is **larger** than under the proxy model.
**Mitigation (load-bearing):** pin provider versions in `versions.tf`, commit
`.terraform.lock.hcl`, pin collection versions in `requirements.yml`, review
changelogs before upgrading.

## Isolation Strength Summary

| Threat | Layer 1 | Layer 2 | Protected? |
|---|---|---|---|
| Reach production Proxmox | IAM (token ACL, privsep) | Credentials absent + segmentation | Yes |
| Read/corrupt production state | MinIO scoped key | Instance unreachable, creds absent | Yes |
| Escalate Proxmox privileges | privsep=1 | Role exclusions | Yes |
| Arbitrary internet egress | — | Permission layer + operator review | No — accepted |
| Exfiltration via git | Push denied to agent | Operator pre-push review | Partial |
| Concurrent apply | Plan-file workflow | Operator coordination | Partial |
| Secrets on controller host | Sandbox-only secrets present | — | Accepted by design |
| Supply chain | Version pinning + lockfiles | Changelog review | Partial |
