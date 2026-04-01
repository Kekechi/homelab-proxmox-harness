# generate

Write Terraform and Ansible code from an approved infrastructure plan using the iac-generator agent (Sonnet).

## Usage

```
/generate
```

Run immediately after approving a plan from `/infra-plan`. No arguments needed — the agent reads the plan from the conversation context.

## What Gets Written

- `terraform/main.tf` — new module calls
- `terraform/variables.tf` — new variables
- `terraform/modules/<name>/` — new modules (only if no existing module fits)
- `ansible/playbooks/` or `ansible/roles/` — Ansible code if the plan includes it

## After Generation

Use `/review` to check the generated code for security and correctness before running `make plan`.

For the full automated pipeline (infra-plan → generate → review → apply), use `/deploy` instead.
