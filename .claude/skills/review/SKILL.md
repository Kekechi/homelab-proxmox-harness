---
name: review
description: Review Terraform and Ansible code for security, bpg/proxmox correctness, and sandbox scope using tf-reviewer (Sonnet). Returns APPROVE/WARN/BLOCK verdict.
disable-model-invocation: false
---

# Skill: Code Review

Launch the **tf-reviewer** agent to review Terraform and Ansible code before any apply.

## Instructions

Think hard about security implications and whether any change could escape sandbox scope before launching the reviewer.

1. Determine scope: if an argument was provided (file path or directory), review that target; otherwise review all modified `.tf` files and changed Ansible files in the working tree
2. Launch the `tf-reviewer` agent (defined in `.claude/agents/tf-reviewer.md`) with the determined scope
3. Present the full review report with verdict

## Verdict Behavior

- **BLOCK** — stop. Do not proceed to `terraform plan` or apply. Present the blocking issues clearly and wait for the user to fix and re-review.
- **WARN** — present warnings and ask the user whether to proceed despite them.
- **APPROVE** — continue to the next step.

## Output Format

The agent produces:

```
## Terraform Review: <files reviewed>

### Issues Found
| # | Severity | File:Line | Issue | Fix |

### Sandbox Scope Verification
- All resources target pool: <pool_id>
- No privilege escalation detected: ✓/✗

### Verdict: APPROVE / WARN / BLOCK
<reasoning>
```
