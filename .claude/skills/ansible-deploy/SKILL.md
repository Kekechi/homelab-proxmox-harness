---
name: ansible-deploy
description: Full pipeline for Ansible role/playbook deployments. Orchestrates infra-plan → generate → review → ansible-run with human checkpoints at each step.
disable-model-invocation: true
---

# Skill: Ansible Deploy Pipeline

Orchestrate the full Planner-Generator-Evaluator (PGE) pipeline for Ansible deployments.

Use this when writing and deploying new Ansible roles or playbooks. For Terraform infrastructure changes, use `tf-deploy` instead. When infrastructure provisioning and service configuration are both needed, run `tf-deploy` first (in its own session), then `ansible-deploy`.

## Pipeline Sequence

### Step 1: Plan

Follow the `infra-plan` skill with the user's request.

**Checkpoint:** Stop and wait for explicit user approval of the plan before proceeding. Accept revisions and re-plan if requested.

The `infra-plan` skill will write the approved plan to `.claude/session/plan-<name>.md`.

### Step 1b: Plan Review

After the user approves the plan, follow the `polish` skill with `plan` on the plan file written in Step 1.

The polish skill reviews the plan for Ansible runtime correctness, fixes any blocking issues in a fixer subagent, and loops until APPROVE. This step is cheap — bugs caught in plan text cost nothing; the same bugs caught after code generation require fixing across multiple files.

**Do not proceed to Step 2 until polish returns APPROVE.**

> **Context reset point:** After Step 1b passes, say: "Plan review is clean. If context is getting long, run `/compact` now — Step 2 reads the plan from `.claude/session/plan-<name>.md`."

### Step 2: Generate

Follow the `generate` skill with the approved and reviewed plan from Step 1.

Continues automatically when `ansible-lint` passes (if configured). If lint fails, surface the errors and stop.

### Step 3: Review

Follow the `polish` skill with `code` on all files modified in Step 2.

The polish skill runs the tf-reviewer subagent, fixes any blocking issues in a fixer subagent, and loops until APPROVE. All fix+re-review cycles stay in subagents — the main session only sees the final verdict.

**After polish resolves:**
- APPROVE — continue.
- WARN — present warnings and ask the user whether to proceed.

> **Context reset point:** After Step 3 APPROVE, say: "Review passed. If context is getting long, run `/compact` before running the playbook — Step 4 doesn't need prior context."

### Step 4: Run

Follow the `ansible-run` skill.

## Constraints

- Run `tf-deploy` in a separate session before this skill if new infrastructure is needed — mixing Terraform and Ansible deployment in one session adds complexity and risks context fragmentation when Ansible debugging is required
- Never skip any checkpoint — each gate exists because the cost of a partial deploy exceeds the cost of pausing
