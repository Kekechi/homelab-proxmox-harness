# Claude Code Skills

This project uses Claude Code skills to structure infrastructure work. Skills are
invoked with a `/skill-name` prefix in the Claude Code prompt.

The workflow philosophy is deliberately light: **an agreed design record is the go
signal**. There are no multi-agent deploy pipelines — the agent designs with you,
executes directly in the sandbox, and proves results with behavioral verification.

---

## Quick Reference

### The core loop

| Skill | Invoke | Auto-loads? | What it does |
|---|---|---|---|
| `design` | `/design <rough idea>` | yes | Explores a design one decision at a time; ends in a committed design record (with an execution boundary for autonomous runs) |
| `free-run` | `/free-run <design record>` | **no** | Executes an agreed design record autonomously: journaled decisions, per-slice commits, verify gates — no orchestration ceremony |
| `review` | `/review [path]` | yes | Single-pass review (tf-reviewer agent): security, bpg/proxmox correctness, component-architecture fit — APPROVE / WARN / BLOCK |
| `handoff` | `/handoff` | **no** | Packages a production plan (diff, risks, exact apply commands) for the operator — the agent never applies to production |

### Assessment and health

| Skill | Invoke | Auto-loads? | What it does |
|---|---|---|---|
| `assess` | `/assess <scope>` | yes | Structured project assessment with discussion |
| `sanity-sweep` | `/sanity-sweep` | yes | Read-only Tier-2 sweep over deployed components; records findings only, never acts |
| `retro` | `/retro` | yes | Retrospective on a completed session; recommends no action / memory / skill update / new skill |

### Operations

| Skill | Invoke | Auto-loads? | What it does |
|---|---|---|---|
| `day2-ops` | `/day2-ops` | **no** | Modifies existing VMs/LXCs (resize, snapshots, network, cloud-init) — config edits + plan review, never `.tf` edits |

Skills marked **no** require explicit invocation and will not be triggered automatically by Claude.

Reference skills (`proxmox-module`, `tf-plan-apply`, `tf-troubleshoot`) are not invoked
directly — Claude loads them automatically when relevant.

---

## The Workflow

### 1. Design

`/design` facilitates a one-decision-at-a-time discussion and produces a design record
under `docs/design/`. For work that will run autonomously, the record includes an
**execution boundary** — what the session may touch and what is out of bounds.

Operator agreement on the record ("looks good") is the go signal.

### 2. Execute

Contained changes: the agent executes directly in-session. Longer autonomous work:

```
/free-run docs/design/<topic>.md
```

The run journals decisions and failures (failures are lessons, not halts), commits per
coherent slice, and never pushes — the operator reviews history and pushes.

### 3. Verify

Every component ships a behavioral `verify.sh`:

```
make verify-<component>   # one component (e.g. make verify-pki)
make verify-all           # every enabled component — the hard gate
/sanity-sweep             # judgment-based Tier-2 read of live state (record-only)
```

### 4. Production

The agent never applies to production:

```
make plan ENV=production
/handoff
```

`/handoff` produces the plan diff, risk assessment, and exact apply commands for the
operator.

`/review` is available at any point as an optional quality gate — before committing
substantial changes, after touching the primitive modules or the generator, and always
before a production handoff.

---

## Assessment

`/assess` runs a structured review of the project or a subsystem. It surfaces hidden
assumptions, checks code against stated design intent, and drives one-decision-at-a-time
discussion before any optional remediation.

A good prompt includes scope, specific concerns, and your design intent:

```
/assess The config management pipeline. Intent: all env config comes from
one YAML per environment. Concerns: are there hardcoded values that should
be parameterized? Context: adding a production environment soon.
```

---

## Day-2 Operations

`/day2-ops` covers modifications to already-deployed VMs and LXCs: disk/memory/CPU
resize, snapshots, network moves, cloud-init changes. Day-2 changes are config edits
(`config/<env>.yml`, or the component manifest's `resources:` default) followed by
`make configure` + plan review — never direct `.tf` edits. Always check the plan output
for `# forces replacement` before applying.

---

## How Skills Relate to Each Other

```
/design    ── decide, one decision at a time → design record (the go signal)
/free-run  ── execute an agreed record autonomously (journal, slices, verify)
/review    ── optional single-pass quality gate (tf-reviewer)
/handoff   ── production only: package the plan for the operator

/assess       ── independent; structured assessment with discussion
/sanity-sweep ── independent; read-only health sweep over deployed components
/retro        ── independent; after a completed session
/day2-ops     ── post-deployment modifications
```

Reference skills (`proxmox-module`, `tf-plan-apply`, `tf-troubleshoot`) are loaded
automatically by Claude when relevant. You do not invoke them directly.

---

## Skill Files

Each skill lives under `.claude/skills/<name>/`:

- `SKILL.md` — instructions for Claude. Every skill has one; its frontmatter
  `description` is the authoritative summary, and `disable-model-invocation: true` is
  what makes a skill explicit-invoke only (the **no** rows above).
- `README.md` — operator-facing usage notes. Only some skills have one:
  [`review`](../../.claude/skills/review/README.md) ·
  [`handoff`](../../.claude/skills/handoff/README.md) ·
  [`assess`](../../.claude/skills/assess/README.md) ·
  [`day2-ops`](../../.claude/skills/day2-ops/README.md)

For every other skill, read its `SKILL.md` directly. The current authoritative skill
list is the "Available Skills" table in [`CLAUDE.md`](../../CLAUDE.md).
