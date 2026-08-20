# review

Review Terraform, Ansible, and component code with the tf-reviewer agent (Sonnet). Checks security, bpg/proxmox correctness, sandbox scope, and component-architecture fit. Returns an APPROVE/WARN/BLOCK verdict.

## Usage

```
/review                    # review all modified terraform/, components/, and ansible/ files
/review components/dns/    # review one component
/review terraform/modules/ # review the primitive modules
```

## Output Format

```
## Review: <files reviewed>

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

- Before committing substantial Terraform, component, or Ansible changes
- After modifying the primitive modules or the generator
- Before handing a production plan to the operator (`/handoff`)
