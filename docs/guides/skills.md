# Claude Code Skills

This project uses Claude Code skills to automate common infrastructure workflows. Skills are invoked with a `/skill-name` prefix in the Claude Code prompt.

---

## Quick Reference

| Skill | Invoke | Auto-loads? | What it does |
|---|---|---|---|
| `infra-plan` | `/infra-plan <description>` | yes | Plans infrastructure changes, waits for your approval |
| `generate` | `/generate` | yes | Writes Terraform/Ansible code from an approved plan |
| `review` | `/review [path]` | yes | Reviews code and returns APPROVE / WARN / BLOCK |
| `tf-deploy` | `/tf-deploy <description>` | **no** | Full Terraform pipeline: plan → generate → review → apply |
| `ansible-deploy` | `/ansible-deploy <description>` | **no** | Full Ansible pipeline: plan → generate → review → run |
| `handoff` | `/handoff` | **no** | Packages a production plan for operator handoff |
| `assess` | `/assess <scope>` | yes | Structured project assessment with discussion |
| `day2-ops` | `/day2-ops` | **no** | Modifies existing VMs/LXCs (resize, snapshots, network) |

Skills marked **no** require explicit invocation and will not be triggered automatically by Claude.

---

## Deployment Workflow

### Full pipeline (recommended)

Use `/tf-deploy` (Terraform) or `/ansible-deploy` (Ansible) when you want Claude to handle everything end-to-end with checkpoints at each step:

```
/tf-deploy a Ubuntu 24.04 VM with 2 cores, 4GB RAM, static IP 192.168.X.X
```

Pipeline: **plan** → *(your approval)* → **generate** → **review** → *(your approval)* → `terraform plan` → *(your approval)* → `terraform apply`

### Step-by-step (manual control)

Use the individual phase skills when you want to pause between steps, iterate on a plan, or run only part of the pipeline:

```
/infra-plan deploy a Ubuntu 24.04 VM with 2 cores, 4GB RAM
```
→ review the plan, request changes if needed, then approve

```
/generate
```
→ code is written; review the diff

```
/review
```
→ security and correctness check; fix any BLOCK issues

Then run `make plan` and `make apply` manually.

### Production changes

Claude cannot apply to production. After planning:

```
make plan ENV=production
/handoff
```

This produces a handoff document with the plan diff, risk assessment, and exact apply commands for the operator.

---

## Assessment

`/assess` runs a structured review of the project or a subsystem. It surfaces hidden assumptions, checks code against stated design intent, and drives one-decision-at-a-time discussion before any optional remediation.

A good prompt includes scope, specific concerns, and your design intent:

```
/assess The config management pipeline. Intent: all env config comes from
one YAML per environment. Concerns: are there hardcoded values that should
be parameterized? Context: adding a production environment soon.
```

---

## Day-2 Operations

`/day2-ops` covers modifications to already-deployed VMs and LXCs:

- Disk, memory, or CPU resize
- Snapshot management
- Adding or changing network interfaces
- Cloud-init reconfiguration

Always check the plan output for `# forces replacement` before applying day-2 changes — some modifications destroy and recreate the resource.

---

## How Skills Relate to Each Other

```
/infra-plan ─┐
/generate   ─┤─ these three are the building blocks
/review     ─┘

/tf-deploy      ── orchestrates all three + terraform plan/apply
/ansible-deploy ── orchestrates all three + ansible run

/handoff ── post-planning, production only
/assess  ── independent; not part of the deploy pipeline
/day2-ops ── post-deployment modifications
```

Reference skills (`proxmox-module`, `tf-plan-apply`, `tf-troubleshoot`) are loaded automatically by Claude when relevant. You do not invoke them directly.

---

## Skill Files

Each skill lives under `.claude/skills/<name>/`:

- `SKILL.md` — instructions for Claude (what to do, which agent to launch, checkpoints)
- `README.md` — this kind of documentation for each individual skill

See the individual `README.md` files for detailed usage, output format, and examples:

- [`.claude/skills/infra-plan/README.md`](../.claude/skills/infra-plan/README.md)
- [`.claude/skills/generate/README.md`](../.claude/skills/generate/README.md)
- [`.claude/skills/review/README.md`](../.claude/skills/review/README.md)
- [`.claude/skills/handoff/README.md`](../.claude/skills/handoff/README.md)
- [`.claude/skills/assess/README.md`](../.claude/skills/assess/README.md)
- [`.claude/skills/day2-ops/README.md`](../.claude/skills/day2-ops/README.md)
