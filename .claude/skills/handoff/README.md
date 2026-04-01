# handoff

Package a production terraform plan for operator handoff. Claude cannot apply production plans — this skill assembles a complete handoff document for the operator to review and apply manually.

## Usage

```
/handoff
```

Run after `make plan ENV=production` has generated `production.tfplan`.

## Output

A markdown document with:
1. **Change Summary** — what this change does and why
2. **Resources Affected** — create/modify/destroy table
3. **Plan Diff** — full `terraform show` output
4. **Risk Assessment** — destructive actions, rollback plan, downtime, dependencies
5. **Apply Instructions** — exact commands for the operator
6. **Post-Apply Steps** — inventory updates, playbooks, verification

## After Handoff

Present the document to the operator via your preferred channel (Slack, email, PR comment). Claude does not send it directly.

## Prerequisites

- `terraform/production.tfplan` must exist (run `make plan ENV=production` first)
- The plan file is gitignored — it must be on disk in the dev container
