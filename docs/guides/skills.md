# Claude Code Skills

This project uses Claude Code skills to automate common infrastructure workflows. Skills are invoked with a `/skill-name` prefix in the Claude Code prompt.

---

## Quick Reference

### Design and assessment

| Skill | Invoke | Auto-loads? | What it does |
|---|---|---|---|
| `design` | `/design <rough idea>` | yes | Explores a design one decision at a time, produces a design record before planning |
| `assess` | `/assess <scope>` | yes | Structured project assessment with discussion |
| `retro` | `/retro` | yes | Retrospective on a completed session; recommends no action / memory / skill update / new skill |
| `sanity-sweep` | `/sanity-sweep` | yes | Read-only Tier-2 sweep over deployed services; records findings only, never acts |

### Plan / generate / review building blocks

| Skill | Invoke | Auto-loads? | What it does |
|---|---|---|---|
| `infra-plan` | `/infra-plan <description>` | yes | Plans infrastructure changes, waits for your approval |
| `generate` | `/generate` | yes | Writes Terraform/Ansible code from an approved plan |
| `review` | `/review [path]` | yes | Reviews code and returns APPROVE / WARN / BLOCK |
| `polish` | `/polish [code\|plan\|design] [name]` | yes | Iterative review-fix loop until APPROVE; all cycles stay in subagents |

### Deployment pipelines

| Skill | Invoke | Auto-loads? | What it does |
|---|---|---|---|
| `tf-deploy` | `/tf-deploy <description>` | **no** | Full Terraform pipeline: plan → generate → review → apply |
| `ansible-deploy` | `/ansible-deploy <description>` | **no** | Full Ansible pipeline: plan → generate → review → run |
| `ansible-run` | `/ansible-run` | **no** | Pre-flight + run + idempotency check when code is already written |
| `handoff` | `/handoff` | **no** | Packages a production plan for operator handoff |
| `day2-ops` | `/day2-ops` | **no** | Modifies existing VMs/LXCs (resize, snapshots, network) |

### Autonomous sessions

| Skill | Invoke | Auto-loads? | What it does |
|---|---|---|---|
| `auto-plan` | `/auto-plan <goal>` | **no** | Plans an autonomous long-running session; produces an executable brief |
| `auto-run` | `/auto-run <brief>` | **no** | Executes an autonomous session from an `/auto-plan` brief; orchestrator-only, journaled |

Skills marked **no** require explicit invocation and will not be triggered automatically by Claude.

Reference skills (`proxmox-module`, `tf-plan-apply`, `tf-troubleshoot`) are not invoked directly — Claude loads them automatically when relevant. See [How Skills Relate to Each Other](#how-skills-relate-to-each-other).

---

## Deployment Workflow

### Full pipeline (recommended)

Use `/tf-deploy` (Terraform) or `/ansible-deploy` (Ansible) when you want Claude to handle everything end-to-end with checkpoints at each step:

```
/tf-deploy a Ubuntu 24.04 VM with 2 cores, 4GB RAM, static IP on the sandbox subnet
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

## Design

`/design` is the pre-planning step for net-new infrastructure. It facilitates a one-decision-at-a-time discussion and produces a design record under `docs/design/`. Use it before `/infra-plan` when tool behavior is unverified or the shape of the solution is still open — reaching for `/infra-plan` first tends to surface as repeated review cycles.

`/polish` then runs an iterative review-fix loop against a design record, a plan doc, or generated code, looping in subagents until the reviewer returns APPROVE — so the main conversation only sees the final verdict:

```
/polish design dns-design
```

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

## Autonomous Sessions

For long unattended runs where pausing for real-time approval would make you the bottleneck, the autonomy pair takes over:

```
/auto-plan <goal>
```
→ harvests the backlog (docs, session records, memories), triages readiness, selects scope, and produces an autonomy contract: an authorization manifest, per-workstream verification criteria, stop conditions, and journal protocol — written as an executable brief.

```
/auto-run <brief>
```
→ executes that brief with an orchestrator-only main thread (execution and read-heavy work delegated to subagents), verifies each step against its declared criterion, stays inside the signed authorization manifest, and journals the run for asynchronous audit.

Both are explicit-invoke only. `/retro` is the natural follow-up once a session completes.

## Session Health

`/sanity-sweep` runs the read-only Tier-2 collectors over the deployed services and judges each one — "is this working as intended? any smell, misconfig, confusing naming, or over-broad scope?" — writing findings to the session verification record. It is record-only: it never acts on a finding and never touches the trust model (provisioner names, scopes, signing), which is a `/design` concern.

## How Skills Relate to Each Other

```
/design ── decide a design (net-new infra) before any planning

/infra-plan ─┐
/generate   ─┤─ these three are the plan/generate/review building blocks
/review     ─┘
/polish     ── wraps review+fix into a loop until APPROVE (design, plan, or code)

/tf-deploy      ── orchestrates plan + generate + review + terraform plan/apply
/ansible-deploy ── orchestrates plan + generate + review + ansible run
/ansible-run    ── run + idempotency check when code is already written

/handoff  ── post-planning, production only
/assess   ── independent; not part of the deploy pipeline
/retro    ── independent; after a completed session
/day2-ops ── post-deployment modifications
/sanity-sweep ── independent; read-only health sweep over deployed services

/auto-plan ── plan a long unattended session ─┐
/auto-run  ── execute that session from the brief ─┘
```

Reference skills (`proxmox-module`, `tf-plan-apply`, `tf-troubleshoot`) are loaded automatically by Claude when relevant. You do not invoke them directly.

---

## Skill Files

Each skill lives under `.claude/skills/<name>/`:

- `SKILL.md` — instructions for Claude (what to do, which agent to launch, checkpoints). Every skill has one; its frontmatter `description` is the authoritative summary, and `disable-model-invocation: true` is what makes a skill explicit-invoke only (the **no** rows above).
- `README.md` — operator-facing usage notes. Only some skills have one.

The skills with a `README.md` (detailed usage, output format, examples):

- [`.claude/skills/infra-plan/README.md`](../.claude/skills/infra-plan/README.md)
- [`.claude/skills/generate/README.md`](../.claude/skills/generate/README.md)
- [`.claude/skills/review/README.md`](../.claude/skills/review/README.md)
- [`.claude/skills/handoff/README.md`](../.claude/skills/handoff/README.md)
- [`.claude/skills/assess/README.md`](../.claude/skills/assess/README.md)
- [`.claude/skills/day2-ops/README.md`](../.claude/skills/day2-ops/README.md)

For every other skill, read its `SKILL.md` directly. The current authoritative skill list is the "Available Skills" table in [`CLAUDE.md`](../../CLAUDE.md).
