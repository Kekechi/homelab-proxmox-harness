---
name: infra-plan
description: Plan an infrastructure change for the Proxmox homelab using iac-planner (Opus). Produces a structured plan and waits for approval before any code is written.
disable-model-invocation: false
---

# Skill: Infrastructure Planning

Launch the **iac-planner** agent to plan an infrastructure change before any code is written.

## Instructions

Think hard about whether the request is well-specified enough to plan. If the description is ambiguous (missing resource type, size, network, or environment), ask clarifying questions before launching the agent.

1. Receive the user's infrastructure request
2. Launch the `iac-planner` agent (defined in `.claude/agents/iac-planner.md`) with the full request description
3. The agent will explore existing modules, check IAM constraints, optionally research bpg/proxmox provider docs, and produce a structured plan
4. Present the plan to the user

## Human Checkpoint

After the plan is produced, **stop and wait for explicit user approval**. Do not proceed to code generation until the user approves (words like "approved", "looks good", "proceed", or equivalent).

If the user requests changes to the plan, relaunch iac-planner with the revised requirements and repeat the checkpoint.

## Artifact

The plan document produced by iac-planner lives in conversation context. Downstream skills (`generate`, `deploy`) read it from there. No file is written.

## Constraints

- Plans are always sandbox-scoped (`/pool/sandbox`)
- Production changes must be noted as "Operator applies manually" — never plan a direct production apply
- iac-planner will flag any required privileges not in the `TerraformSandbox` role
