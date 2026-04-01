# review

Review Terraform and Ansible code with the tf-reviewer agent (Sonnet). Checks security, bpg/proxmox correctness, sandbox scope, and module quality. Returns an APPROVE/WARN/BLOCK verdict.

## Usage

```
/review                   # review all modified terraform/ and ansible/ files
/review terraform/        # review entire terraform directory
/review terraform/main.tf # review specific file
```

## Output Format

```
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

- After `/generate` writes code (or automatically as a step in `/deploy`)
- Before committing manually written Terraform
- After modifying existing modules
- Before handing a production plan to the operator
