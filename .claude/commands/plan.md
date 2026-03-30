---
description: Plan an infrastructure change using iac-planner (Opus). Produces a structured plan document and waits for approval before any code is written.
allowed_tools: ["Read", "Grep", "Glob", "Bash", "WebSearch", "WebFetch"]
---

# /plan

Plan an infrastructure change for the Proxmox homelab sandbox.

## What This Command Does

1. Launches the **iac-planner** agent (Opus) with your description
2. iac-planner reads existing modules, checks IAM constraints, and optionally researches the bpg/proxmox provider docs
3. Produces a structured plan: resources, variables, dependency order, risk assessment
4. Presents the plan for your review — **no code is written yet**

## Usage

```
/plan <description of what you want to deploy or change>
```

**Examples:**
- `/plan deploy a Ubuntu 24.04 VM with 2 cores and 4GB RAM in the sandbox VLAN`
- `/plan create an LXC for running a small nginx reverse proxy`
- `/plan add a Linux bridge on vmbr1 for a second VLAN`

## Output Format

The plan includes:
- **Resources table** — what will be created/modified/destroyed and at what risk
- **Variables Required** — what values you need to supply in `sandbox.tfvars`
- **Dependency Order** — what must be provisioned in what sequence
- **Risk Assessment** — destructive actions, rollback plan, sandbox scope confirmation
- **Implementation Notes** — provider-specific quirks

## After the Plan

If the plan looks correct, use `/deploy` to run the full pipeline, or use `/generate` to write code from the plan and then review manually.

## Constraints

- Plans are always sandbox-scoped (`/pool/sandbox`)
- Production changes are planned with a note: "Operator applies manually"
- iac-planner will flag any required privileges not in the `TerraformSandbox` role
