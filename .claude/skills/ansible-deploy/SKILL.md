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

### Step 2: Generate

Follow the `generate` skill with the approved plan from Step 1.

Continues automatically when `ansible-lint` passes (if configured). If lint fails, surface the errors and stop.

### Step 3: Review

Follow the `review` skill on all files modified in Step 2.

**Checkpoint:**
- BLOCK — present blocking issues, stop. Do not proceed until fixed and re-reviewed.
- WARN — present warnings and ask the user whether to proceed.
- APPROVE — continue.

### Step 4: Run

Follow the `ansible-run` skill.

## Constraints

- Run `tf-deploy` in a separate session before this skill if new infrastructure is needed — mixing Terraform and Ansible deployment in one session adds complexity and risks context fragmentation when Ansible debugging is required
- Never skip any checkpoint — each gate exists because the cost of a partial deploy exceeds the cost of pausing
