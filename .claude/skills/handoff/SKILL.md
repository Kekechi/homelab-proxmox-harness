---
name: handoff
description: Package a production terraform plan with context for operator handoff. Assembles change summary, risk assessment, plan diff, and exact apply commands.
disable-model-invocation: true
---

# Skill: Production Handoff

Package a production plan for operator handoff. Claude cannot apply production plans — the operator must review and apply manually.

## Instructions

1. Check that `terraform/production.tfplan` exists. If it does not, stop and instruct the user to run `make plan ENV=production` first.
2. Run `terraform show production.tfplan` to capture the human-readable diff
3. Assemble and output the handoff document below

## Handoff Document

Produce a markdown document with these sections:

### 1. Change Summary
One-paragraph description of what this change does and why. Reference the original request or plan context from the conversation.

### 2. Resources Affected
| Action | Resource | Key Details |
|---|---|---|
| create/modify/destroy | `module.name.resource.id` | Size, IP, pool, etc. |

### 3. Plan Diff
Full output of `terraform show production.tfplan` in a code block.

### 4. Risk Assessment
- **Destructive actions:** List any destroy or replace operations
- **Rollback plan:** How to undo if something goes wrong
- **Downtime:** Whether existing resources will be interrupted
- **Dependencies:** Other systems affected (Ansible inventory, DNS, monitoring)

### 5. Apply Instructions
```bash
cd terraform
terraform show production.tfplan   # verify the plan matches expectations
terraform apply production.tfplan
terraform state list
terraform output -json
```

### 6. Post-Apply Steps
- Configuration updates needed (inventory, DNS, monitoring)
- Ansible playbooks to run
- Verification checks

## Constraints

- Read-only — do not modify any files
- Do not send the handoff document anywhere — present it to the user for delivery via their preferred channel
