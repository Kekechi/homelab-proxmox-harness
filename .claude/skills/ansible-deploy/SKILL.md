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

### Step 1b: Plan Review

After the user approves the plan, launch a general-purpose subagent to review it for runtime correctness before any code is written. The planner produces structurally sound plans but does not always think through Ansible runtime mechanics.

Check for:
- Missing module arguments that cause silent failures (`headers:` on `uri`, `status_code:` lists, `changed_when:` on `shell` tasks)
- Idempotency gaps (unguarded commands, missing `stat` checks before init tasks, `when:` conditions that skip cleanup)
- Service ordering dependencies (handler flush timing, `wait_for` placement before API calls)
- Template correctness (YAML quoting, config key names matching the target software version)
- String format mismatches between tool input syntax and tool output syntax (e.g. `setcap` uses `+ep`, `getcap` outputs `=ep`)
- JSON body type fidelity: when `uri` uses `body_format: json`, verify that Jinja2-templated values land as the correct JSON type (int, bool, list). Quoted YAML scalars (`"{{ x }}"`) pass through `to_text()` — `| int` alone does not guarantee a JSON integer unless `jinja2_native = true` is set in `ansible.cfg`. Verify the target API accepts string values, or restructure to avoid the ambiguity.

Fix issues found, re-review until the subagent confirms no blocking issues remain. This step is cheap — bugs caught in plan text cost nothing; the same bugs caught after code generation require fixing across multiple files.

**Do not proceed to Step 2 until the plan review is clean.**

### Step 2: Generate

Follow the `generate` skill with the approved and reviewed plan from Step 1.

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
