---
description: Write Terraform and Ansible code from an approved plan. Invokes iac-generator to translate a plan document into working code.
allowed_tools: ["Read", "Grep", "Glob", "Bash", "Write", "Edit"]
---

# /generate

Generate code from an approved infrastructure plan using the iac-generator agent.

## What This Command Does

1. Reads the approved plan from the current conversation (produced by `/plan`)
2. Launches **iac-generator** (Sonnet) to write Terraform and Ansible code
3. iac-generator adds module calls to `terraform/main.tf`, variables to `terraform/variables.tf`, and new modules if needed
4. Runs `terraform validate` + `tflint` internally and reports results
5. Suggests running `/review` to review the generated code before applying

## Usage

```
/generate
```

Run immediately after approving a plan from `/plan`. No arguments needed — the agent reads the plan from the conversation context.

## What Gets Written

- `terraform/main.tf` — new module calls
- `terraform/variables.tf` — new variables
- `terraform/modules/<name>/` — new modules (only if no existing module fits)
- `ansible/playbooks/` or `ansible/roles/` — Ansible code if the plan includes it

## After Generation

Use `/review` to check the generated code for security and correctness before running `make plan`.

For the full automated pipeline (plan → generate → review → apply), use `/deploy` instead.
