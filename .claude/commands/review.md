---
description: Review Terraform and Ansible code using tf-reviewer. Checks security, bpg/proxmox correctness, sandbox scope, and module quality. Returns APPROVE/WARN/BLOCK verdict.
allowed_tools: ["Read", "Grep", "Glob", "Bash"]
---

# /review

Review Terraform and Ansible code with the tf-reviewer agent.

## What This Command Does

Launches **tf-reviewer** (Sonnet) to review code against the full checklist:

- **Security (CRITICAL):** credentials, pool scope, sensitive vars, no `.tfstate` commits
- **Terraform correctness:** version pins, backend config, variable descriptions, outputs
- **bpg/proxmox specifics:** resource names, CPU type, disk/network conventions, cloud-init
- **Module quality:** no hardcoded env values, useful outputs, correct dynamic blocks
- **Ansible (if applicable):** FQCN, no hardcoded IPs, SSH ProxyCommand preserved

## Usage

```
/review                   # review all modified terraform/ and ansible/ files
/review terraform/        # review entire terraform directory
/review terraform/main.tf # review specific file
```

## Output Format

```markdown
## Terraform Review: <files reviewed>

### Issues Found
| # | Severity | File:Line | Issue | Fix |
|---|----------|-----------|-------|-----|

### Sandbox Scope Verification
- All resources target pool: <pool_id>
- No privilege escalation detected: ✓/✗

### Verdict: APPROVE / WARN / BLOCK
<reasoning>
```

## Severity Levels

| Level | Action |
|---|---|
| CRITICAL | BLOCK — must fix before apply |
| HIGH | WARN — should fix before apply |
| MEDIUM | INFO — consider fixing |
| LOW | NOTE — optional |

## When to Use

- After `/deploy` generates code (automatic in the pipeline)
- Before committing manually written Terraform
- After modifying existing modules
- Before handing a production plan to the operator
