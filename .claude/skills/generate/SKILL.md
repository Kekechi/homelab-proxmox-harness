---
name: generate
description: Write Terraform and Ansible code from an approved infrastructure plan using iac-generator (Sonnet).
disable-model-invocation: false
---

# Skill: Code Generation

Launch the **iac-generator** agent to translate an approved infrastructure plan into working Terraform and Ansible code.

## Instructions

1. **Locate the approved plan.** Check in order:
   - Conversation context (plan text present from a recent `/infra-plan` run)
   - `.claude/session/plan-*.md` — if context was cleared or compacted after planning, read the plan file and pass it to the agent
   - If no plan is found in either location, ask the user to run `/infra-plan` first or provide the plan directly.
2. Launch the `iac-generator` agent (defined in `.claude/agents/iac-generator.md`) with the approved plan as context
3. The agent will write code to the appropriate files
4. Run `make lint` after generation completes — this catches mechanical issues
   (naming conventions, key ordering, deprecated patterns) before review.
   Fix any lint violations before proceeding.
5. Present lint results to the user

## What Gets Written

- `terraform/main.tf` — new module calls
- `terraform/variables.tf` — new variables
- `terraform/modules/<name>/` — new modules (only if no existing module fits)
- `ansible/playbooks/` or `ansible/roles/` — Ansible code if the plan includes it

## After Generation

Suggest running `/review` to check the generated code for security and correctness before applying.

For the full automated pipeline, use `/deploy` instead of running infra-plan → generate → review manually.
