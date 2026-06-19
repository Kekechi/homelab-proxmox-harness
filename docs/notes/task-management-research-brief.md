# Research Brief — Task Management for Long-Horizon Autonomous Sessions

**Date:** 2026-06-18 · **For:** a `/deep-research` pass in its own session · **Output:** a cited report to `docs/notes/`, read later by whoever does the skills v2.

This brief is self-sufficient — it carries the distilled conclusions a researcher needs, not the originating conversation. (Deeper context, if wanted: `.claude/skills/auto-plan/SKILL.md`, `.claude/skills/auto-run/SKILL.md`, and `.claude/session/skill-improvement-working-2026-06-18.md`.)

## Research question

> How do mature long-horizon agent systems **represent, track, and adapt a task set** — task-state machines, inter-task dependency DAGs, re-planning triggers on discovered work, budget/context-aware prioritization, and bounding hierarchical/ballooning tasks — under a constraint where worker subagents are **fire-and-return (non-resumable)**? Split findings into **plan-time** (building the task structure) vs. **runtime** (operating it).

## What we're building (so findings can be targeted, not generic)

A pair of skills for autonomous long-running engineering sessions:
- **`/auto-plan`** produces the task structure (a brief: sequenced workstreams + an *autonomy contract*).
- **`/auto-run`** executes under it with the operator out of the real-time loop.

Task management has **two perspectives linked by one shared artifact, an inter-workstream dependency graph (DAG)** — `/auto-plan` produces the DAG, `/auto-run` consumes it. That handoff is the heart of what we want the research to sharpen.

## Hard constraints (these decide which findings are usable)

1. **Workers are fire-and-return / non-resumable.** A subagent cannot be paused and resumed or re-woken by message. Continuation across the escalation boundary is done by an **artifact-file relay**: agent A writes its full context to a file and returns a short summary; the orchestrator decides; agent B is spawned with the file and *rehydrates* A's context. Most agent literature assumes long-lived/resumable agents — we specifically need patterns that survive non-resumable workers.
2. **The orchestrator's context is scarce and permanent.** The main thread must decide from short summaries, never by reading detail into its own context. Any runtime task-state representation must be **summary-sized in the orchestrator**, with bulk living in files/subagents.
3. **Composes with an existing four-clause autonomy contract** (authorization manifest, per-workstream verification criterion, stop conditions, journal). Task management is an *extension* of this frame, not a replacement.
4. **Single operator, async-audit model.** The operator sets intent + boundary up front and audits after; the run escalates only the genuinely novel. Sandbox/homelab stakes.
5. A harness task primitive exists but is **unused** (`TaskCreate` / `TaskList` / `TaskUpdate`) — evaluate whether it's the right runtime task-state store.

## Specific gaps to investigate

**Plan-time (`/auto-plan`):**
- Cheap, explicit notations for an **inter-workstream dependency DAG** (granularity, how much is worth modeling).
- Decomposition strategies and **bounding hierarchical / ballooning tasks** — e.g. a task that repairs the very harness the run verifies against and expands unpredictably (one "wire the gate" task uncovered 6 latent sub-bugs).
- Readiness triage and scope-selection patterns before committing a task set.

**Runtime (`/auto-run`):**
- **Task-state machines** for long agent runs: useful state sets and transitions (pending / in-progress / blocked / shelved / done / deferred?).
- **Blocker isolation + halt-scope:** how systems decide whether a blocker shelves *only its dependents* (continue independent work), or halts the whole run. What signals distinguish a local blocker from a systemic one.
- **Re-planning triggers:** when discovered work should trigger a re-plan vs. be absorbed silently vs. escalate.
- **Budget / context-aware prioritization:** choosing the next task under a finite budget.

**Cross-cutting:**
- How the **DAG is best shared** between a planning phase and an execution phase.
- How **non-resumable workers** change each of the above vs. the resumable-agent assumption in most sources.

## Already decided — do NOT re-derive

- **Context management is solved empirically** (delegate execution *and* diagnosis; "every byte the orchestrator reads is permanent"; artifact-relay for continuation). Not the research target.
- The **four-clause contract**, **structural-over-instructional** (enforce rules via schema returns / deny rules, not prose), and **verify-before-you-depend** are settled principles — assume them.
- Assume a sophisticated baseline; skip "what is an agent / what is RAG" foundational material.

## Deliverable shape

A cited report that:
1. Splits findings **plan-time vs runtime**.
2. For each pattern, notes **applicability under the fire-and-return constraint** (does it survive non-resumable workers, or does it assume resumability?).
3. Ends with **concrete recommendations mapped to `/auto-plan` and `/auto-run`**, including a verdict on whether to adopt the harness `Task*` tools as the runtime state store.
