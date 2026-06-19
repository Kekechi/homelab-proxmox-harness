# Research Report — Task Representation, Tracking, and Adaptation for Long-Horizon Autonomous Sessions

**Date:** 2026-06-18 · **For:** the skills-v2 design of `/auto-plan` + `/auto-run`
**Companion:** `docs/notes/task-management-research-brief.md` (the question this answers)

This report synthesizes 21 adversarially-verified claims drawn from primary academic sources (ADaPT, ROMA, ReCAP, GAP, TDP, MAST, TRIAGE), the official Claude Code / Agent SDK docs and live tool schemas, and framework bug trackers. Findings are split **plan-time vs runtime**; every pattern is annotated for **applicability under the fire-and-return (non-resumable worker) constraint**. Recommendations mapped to the two skills follow, including a verdict on the harness `Task*` primitives.

The single most important framing: most agent literature assumes a **resumable** agent that carries full history. Our constraint is the opposite — workers are fire-and-return, continuation happens via an artifact-file relay. The patterns that survive are exactly those built on **node-scoped context** (a node is dispatched with predecessor outcomes + its own trace, never the global history) and **compressive bottom-up aggregation** (children return synthesized answers, not raw context). TDP and ROMA both independently arrive at this shape, which is structurally identical to our relay model.

---

## Plan-time findings (building the task structure)

### P1. The plan-time artifact should be a dependency-aware DAG of sub-goals, authored by a role separate from execution
**Confidence: high** (TDP, ROMA, GAP — three primary sources, unanimous)

TDP (arXiv:2601.07577) decomposes a long-horizon task at plan-time into a DAG of sub-goals produced by a dedicated **Supervisor** role, distinct from the Planner/Executor that run each node. This directly corroborates the `/auto-plan` → `/auto-run` separation: a plan-time decomposer emits the DAG; runtime roles consume it. ROMA (arXiv:2602.01848) and GAP (arXiv:2510.25320) reinforce that explicit dependency graphs are the mature representation — GAP faults ReAct precisely for "sequential reasoning... failing to exploit the inherent parallelism" that an explicit DAG exposes.

*Fire-and-return applicability:* **Survives, and is in fact the natural fit.** The DAG is a static artifact authored once and handed across the phase boundary — it does not assume a resumable author. Caveat: TDP's runtime *Self-Revision* module mutates the DAG mid-run assuming co-running roles; that mutation mechanism does not transfer (see R3).

### P2. A cheap, concrete DAG notation already exists: per-node `{goal, type, dependencies}` plus an optional adjacency map
**Confidence: high** (ROMA — primary source + implementation repo)

ROMA's `SubTask` is a small Pydantic record carrying exactly three fields — `goal`, `task_type`, `dependencies` — and the graph is an optional adjacency map `dependencies_graph: Optional[Dict[str, List[str]]]`. `task_type` is a MECE enum. This is the cheapest defensible notation: a list of nodes, each naming its goal and its prerequisite node IDs. Granularity in ROMA is **sibling-level** (index references among one parent's children), applied recursively per level — which maps cleanly onto inter-workstream granularity for `/auto-plan` (the top level *is* the workstream DAG).

*Fire-and-return applicability:* **Survives.** An adjacency map of IDs is a pure data artifact; rehydration just means a fresh worker reads its predecessors' outputs by ID from files.

### P3. Decomposition should be MECE and dependency-aware, with parallel-vs-sequential order *read off* the DAG, not decided ad hoc
**Confidence: high** (ROMA, GAP — primary)

ROMA's Planner produces MECE (mutually-exclusive, collectively-exhaustive) subtask DAGs. GAP derives execution order by **topological sort**: partition into levels L0..Lk, all nodes in a level are independent, the agent blocks until every result in a level returns before advancing. The lesson for `/auto-plan`: encode dependencies, then let ordering be a deterministic function of the graph rather than a separately-authored sequence. This also tells the orchestrator *what may proceed in parallel* and *what must wait*.

*Fire-and-return applicability:* **Survives cleanly.** Topological level-partitioning is a property of the static graph. GAP itself assumes a single resumable agent batching tool calls, but the *level decomposition* is orchestrator-side and transfers directly: dispatch a level's independent workstreams, wait for all returns, advance.

### P4. Bound ballooning/hierarchical tasks with an explicit recursion bound — either a depth cap (d_max) or an atomicity gate
**Confidence: high** (ADaPT, ROMA, ReCAP — primary, unanimous)

Three independent mechanisms for the "one task uncovers 6 latent sub-bugs" problem:
- **ADaPT (arXiv:2311.05772):** explicit maximum-depth parameter `d_max` (studied at {1,2,3}); recursion simply stops at the cap.
- **ROMA:** an **Atomizer** makes a per-node binary atomic/non-atomic decision; recursion halts when a node is judged atomic — a *content-based* bound rather than a fixed depth.
- **ReCAP (arXiv:2510.23822):** bounds the *active prompt* (sliding window, K≈64) so cost scales **linearly with task depth** rather than ballooning; critical planning info is reintroduced by structured injection so truncation never loses high-level intent.

These are complementary: a depth cap bounds the *tree*, an atomicity gate bounds *whether to recurse at all*, and a prompt cap bounds *context cost per level*.

*Fire-and-return applicability:* **All survive.** A depth counter is a scalar carried in the relay artifact. The atomicity decision is made fresh per node by the spawning orchestrator, needing no resumable state. ReCAP's prompt cap is exactly the orchestrator-context-scarcity discipline we already hold.

### P5. Decompose lazily — attempt first, decompose only on failure — but enumerate the plan up front to preserve global intent
**Confidence: high** (ADaPT, ReCAP — primary)

There is real tension here, resolved by combining two findings. ADaPT decomposes **on demand**: the executor attempts a task whole, and the planner is invoked to decompose *only when execution fails*. This avoids over-planning shallow tasks. ReCAP's **plan-ahead decomposition** counters the opposite failure: it enumerates the full ordered subtask list up front, executes the head item, then refines the remainder — preserving global intent and avoiding myopic "plan drift." The synthesis for `/auto-plan`: enumerate the workstream set up front (ReCAP, for global coherence), but let each workstream's *internal* sub-decomposition be lazy/on-failure (ADaPT, to avoid speculative over-planning).

*Fire-and-return applicability:* ADaPT's execute-first/decompose-on-failure is **runtime** and survives (failure is observed in a return summary, triggering a fresh decomposition spawn). ReCAP's "refine the remainder" step is interleaved/runtime and mildly assumes feedback-into-context; under fire-and-return the refinement is an orchestrator decision fed by the prior worker's summary, not in-agent continuation.

### P6. Subtask composition can be annotated with a simple logical operator (And/Or)
**Confidence: high** (ADaPT — primary)

ADaPT's planner emits an **And/Or operator** alongside the subtasks: `And` = all must succeed (sequential conjunction), `Or` = any suffices (alternative disjunction). This is a near-free addition to the DAG notation that captures "these are alternatives, only one needs to land" vs. "all are required" — useful for fallback workstreams.

*Fire-and-return applicability:* **Survives** — a per-edge/per-group annotation in the static artifact.

---

## Runtime findings (operating the task structure)

### R1. Each worker must receive only node-scoped context (predecessor outcomes + its own trace) — this is the fire-and-return relay, validated
**Confidence: high** (TDP — primary)

This is the keystone runtime finding. TDP dispatches each module with **only** (i) the current node spec and (ii) a compact node-scoped context = prerequisite-node outcomes + the trace accumulated *on the current node*. Modules "never consume the full global execution history." This is **functionally identical** to our artifact-file relay: a fresh worker rehydrates only its predecessors' outputs from files. TDP independently confirms the pattern survives — indeed *requires* — non-resumable per-node spawning.

*Fire-and-return applicability:* **This IS the fire-and-return model.** The absence of cross-node history carry is the defining property; no resumable agent is assumed.

### R2. Aggregation must be compressive (synthesize, not concatenate) — this is what controls context growth across the relay
**Confidence: high** (ROMA — primary)

ROMA's Aggregator "produces the answer to the original parent task, not just raw child outputs"; aggregation "compresses and validates intermediate results to control context growth." Mapped to our constraint: a worker's return summary up the tree must be a *synthesized answer*, not a transcript. This is precisely how the orchestrator's permanent context stays summary-sized while bulk lives in files.

*Fire-and-return applicability:* **Maps directly.** Children return synthesized summaries; the full context they wrote stays in the relay file for the *next* worker, not the orchestrator. (Minor source nuance: ROMA splits *validation* into a separate Verifier — see R6 — so "aggregation validates" is loose; treat synthesis and verification as two steps.)

### R3. Re-planning should be node-local: trigger only when observations substantially conflict with expected progress, and confine the re-plan to the active node
**Confidence: high** (TDP — primary; ADaPT corroborates the failure-trigger)

TDP triggers replanning **only when observations substantially conflict with expected progress**, and restricts it to the active node: "only its plan and local execution trace are revised, while completed prerequisite nodes and causally independent nodes remain unchanged." This is the concrete re-plan-vs-absorb-vs-escalate rule the brief asks for: a *local deviation is repaired locally* rather than escalating to a whole-run re-plan. ADaPT's decompose-on-failure is the same trigger shape at the decomposition layer.

*Fire-and-return applicability:* **Survives.** Node-local replanning means spawning a fresh worker for *one* node with revised scope — no resumability needed. The orchestrator decides this from the conflicting return summary. (Caveat: TDP's own *Self-Revision* assumes a co-running mutator; we replace it with an orchestrator-mediated re-spawn.)

### R4. Failure is a separately-failing concern from doing the work — a "done" transition MUST require explicit verification
**Confidence: high** (MAST — primary, peer-reviewed, κ=0.88)

MAST (arXiv:2503.13657) is an empirical taxonomy of 14 failure modes in 3 categories from 1600+ traces across 7 frameworks. Its **Task Verification** category contains three *distinct* failure modes — Premature Termination (agent stops before completion, 6.2%), No/Incomplete Verification (8.2%), Incorrect Verification (9.1%) — establishing that "is this task actually done?" fails independently of "was the work done." The direct implication for our state machine: **never collapse "agent returned" into "done."** A fire-and-return worker's return summary cannot be trusted as a done-signal; the `done` transition must gate on an explicit verification step. This is exactly the four-clause contract's per-workstream verification criterion, now empirically grounded.

*Fire-and-return applicability:* **Strengthened by the constraint.** Because the orchestrator only sees a short summary, an unverified self-reported "done" is even more dangerous than in a resumable system where state is inspectable. Verification must be a structural transition, not trust.

### R5. The failure surface splits design-time vs runtime — mirroring the plan-time/runtime split
**Confidence: high** (MAST — primary)

MAST's 3 categories: (i) system/specification *design* issues, (ii) inter-agent *misalignment*, (iii) task *verification/termination*. Category (i) is plan-time (bad specification/decomposition); (ii)+(iii) are runtime (coordination + verification). This validates the brief's plan-time/runtime split as the right axis to organize defenses along — and tells us where to invest: decomposition quality at plan-time, coordination + verification at runtime. (Mild caveat: MAST acknowledges category overlap, so "splits cleanly" is slightly strong.)

*Fire-and-return applicability:* Taxonomy is architecture-agnostic; the mapping is ours.

### R6. The artifact relay reproduces "information withholding" / "loss of conversation history" as a *structural* hazard — so the relay file must carry FULL context, not a lossy summary
**Confidence: medium** (MAST — primary catalog; 2-1 vote; the fire-and-return mapping is the analyst's bridge, not a paper claim)

MAST catalogs Information Withholding (0.8%), Ignored Other Agent's Input (1.9%), Loss of Conversation History, and Conversation Reset as *behavioral* failures in resumable/conversational MAS. The inference for our design: under fire-and-return, if agent A's *return summary* is treated as the handoff (rather than A's full written file), the system reproduces these as a **structural** hazard — B cannot rehydrate what A withheld. Hence the relay artifact (the file B reads) must carry full context; only the *orchestrator-facing* summary is lossy. This reconciles with R2: two channels — a synthesized summary up to the orchestrator, a full-context file across to the next worker.

*Fire-and-return applicability:* This is the core design tension the constraint creates. The split vote reflects that the structural-hazard framing is an inference, not a MAST finding — treat the *catalog* as high-confidence and the *mapping* as a well-reasoned design principle.

### R7. Budget-aware prioritization is best framed as a plan-time prospective commitment, not a runtime re-optimization
**Confidence: medium** (TRIAGE — primary; the runtime-loop analogy is imperfect)

TRIAGE (arXiv:2605.13414) frames resource-constrained control as **prospective**: under a finite token budget, decide which tasks to attempt, in what order, and how much compute each gets — "all before any execution feedback is available." This supports committing workstream order + rough budget weights at `/auto-plan` time rather than re-deciding at runtime. **Important refutation context:** the finer claim that this decomposes into three independent ex-ante functions (selection/allocation/termination committed with *zero* runtime feedback) was **refuted 0-3** — because our orchestrator *does* receive per-worker return summaries between dispatches, so it is not feedback-free at the run level. The prospective-commitment framing applies cleanly to `/auto-plan`'s up-front ordering; runtime retains the ability to re-prioritize on returns.

*Fire-and-return applicability:* **Partial.** Plan-time commitment survives (it is inherently feedback-free). The runtime loop is *not* feedback-free under our model (summaries arrive between dispatches), so do not over-commit to pure ex-ante allocation.

### R8. A worker with an unguarded spawn/Task tool recurses to unbounded depth — workers must NOT get an ungated spawn primitive
**Confidence: high** (opencode #18100 + Claude Code v2.1.172 fix — corroborated across frameworks)

opencode issue #18100 documents fire-and-return subagents spawning children with **no depth limit** — a reproduction hit 47 sessions at 20 levels, where intermediate agents "merely re-delegated work rather than performing it." Corroborated by anthropics/claude-code #68619, kilocode #8637, codex #9912. The structural fix is now shipped: **Claude Code v2.1.172 (2026-06-10) caps depth at 5 and withholds the Agent tool from depth-5 subagents** — a framework-level guard, exactly the structural-over-instructional enforcement we favor.

*Fire-and-return applicability:* **Directly relevant and a hard requirement.** `/auto-run` workers must either not receive a Task/spawn primitive, or be bounded by a depth guard (deny rule / no-Task-at-depth). This is the runtime defense for the "ballooning task" / "harness-repairs-harness" hazard at the spawn layer (complementing the plan-time bounds in P4).

---

## Cross-cutting: harness `Task*` primitives — adopt or keep an artifact file?

### Findings on the harness primitives
**Confidence: high** (official docs + live tool schemas + on-disk verification)

- **The harness now ships structured Task tools as the primary store.** As of TS Agent SDK 0.3.142 / Claude Code v2.1.142, sessions use `TaskCreate / TaskUpdate / TaskGet / TaskList` instead of `TodoWrite`; `TodoWrite` is retained only as a legacy single-session system. (Note: the brief called these "unused" — that is now stale; they are the default store.)
- **They model a dependency DAG natively.** `TaskUpdate` exposes `addBlockedBy` / `addBlocks` (bidirectional dependency edges); `TaskList` *enforces* them: "tasks with blockedBy cannot be claimed until dependencies resolve." Status workflow is native (`pending → in_progress → completed`), with guidance to mark `completed` only after verification and "Never mark completed if tests are failing."
- **They persist outside the session.** Tasks live in `~/.claude/tasks/<session-uuid>/N.json` (home dir, not project), survive context compaction, and broadcast across sessions. On-disk schema is `{id, subject, description, owner, status, blocks, blockedBy}`.
- **Caveat (medium / 2-1):** persistence is **not auto-reconciled** — claude-code issue #29751 shows stale `in_progress`/`pending` tasks leak forward across compaction. The store survives context loss but is *not self-cleaning*; it needs explicit state hygiene. Also: Task tools bypass PreToolUse/PostToolUse hooks (#20243), and the store is session-UUID-scoped, complicating a clean plan→run handoff as a single shared object.

### The available task-state set (refuted-claim note)
The claim that the SDK todo model uses *exactly* three states (`pending/in_progress/completed`) as "the canonical state set" was **refuted 0-3** — it is the harness's set, not a normative recommendation, and our brief's richer set (pending / in-progress / blocked / shelved / done / deferred) is not contradicted by any source. The literature supports a richer machine: `blocked` is implied by R3/R1 dependency gating; `shelved`/`deferred` by R3's "shelve dependents, continue independent work." Design the state set from the *requirements*, not from the harness default.

---

## Concrete recommendations

### For `/auto-plan` (build the DAG)
1. **Emit the workstream DAG as ROMA-style records** (P2): each workstream `{goal, type, dependencies: [ids]}` plus an adjacency map. Keep granularity at workstream level (top of ROMA's recursive tree).
2. **Author it via a planner role separate from execution** (P1, TDP) — already the `/auto-plan` vs `/auto-run` split; this is corroborated, keep it.
3. **Let ordering be derived, not hand-sequenced** (P3, GAP): topological level-partition the DAG so the runtime knows what can parallelize and what must wait.
4. **Set explicit bounds up front** (P4): a workstream-internal decomposition `d_max`, and/or an atomicity rule ("a sub-task that would spawn its own sub-tasks must escalate, not recurse silently"). This is the plan-time defense against the "wire-the-gate → 6 sub-bugs" balloon.
5. **Enumerate workstreams fully but decompose internals lazily** (P5): full set up front for global coherence; ADaPT-style on-failure decomposition inside a workstream.
6. **Annotate alternatives with And/Or** (P6) where fallback workstreams exist.
7. **Commit ordering + rough budget weights prospectively** (R7, TRIAGE) — but do not bake in zero-feedback per-task allocation; the runtime sees returns.

### For `/auto-run` (operate the DAG)
1. **Dispatch each worker with node-scoped context only** (R1, TDP): predecessor outputs (by ID, from relay files) + the task spec. This is the relay model, now validated as the mature pattern.
2. **Two-channel return** (R2 + R6): worker writes a **full-context file** for the next worker, and returns a **synthesized summary** to the orchestrator. Never let the lossy summary be the cross-worker handoff.
3. **Gate the `done` transition on explicit verification** (R4, MAST): a return summary is never a done-signal; transition to `done` only after the per-workstream verification criterion passes. Treat "verified-done" and "agent-returned" as different states.
4. **Make re-planning node-local by default** (R3, TDP): a blocker shelves its *dependents* and the orchestrator continues causally-independent workstreams; escalate to a whole-run re-plan only when the conflict is systemic (e.g., a failed prerequisite that the DAG shows everything depends on, or a verification-criterion that itself is invalid). The DAG's dependency edges *are* the halt-scope signal — local blocker = bounded dependent set; systemic = blocks a high-fan-out node.
5. **Withhold (or depth-guard) the spawn primitive from workers** (R8): structural enforcement, mirroring Claude Code's depth-5 cap. This bounds the runtime balloon at the spawn layer.
6. **Use a richer state set than the harness default** (cross-cutting): `pending / ready / in_progress / blocked / shelved / done(verified) / deferred`. Derive from requirements (R3/R4), not the three-state harness default.

### Verdict on harness `Task*` as the runtime state-store
**Keep task state in the artifact file (the DAG/journal); do NOT adopt `Task*` as the primary runtime store — but mirror a thin status view into it if cheap.**

Reasoning:
- **Pro-adoption:** native `addBlockedBy` DAG modeling with *enforced* gating (cannot claim a blocked task), native `pending→in_progress→completed` with verify-before-complete guidance, and home-dir persistence surviving compaction. These align with R1/R3/R4.
- **Disqualifying frictions for *our* model:**
  - **No clean plan→run handoff object.** The store is session-UUID-scoped; our DAG must cross the `/auto-plan`→`/auto-run` boundary as a *shared, operator-auditable artifact*. A file in the repo/journal is the natural shared object; the Task store is per-session and not designed as a phase-handoff artifact.
  - **Not self-cleaning** (#29751): stale `in_progress` leaks across compaction. Our run is long and compaction-prone; a store that silently carries stale state contradicts R4's verify-gated `done`.
  - **State set too thin.** Three states cannot express `blocked`/`shelved`/`deferred` natively (only `blockedBy` gating). Our halt-scope logic (R3) needs `shelved`.
  - **Bypasses hooks** (#20243): we rely on structural enforcement (deny rules, schema returns); a store that sidesteps PreToolUse/PostToolUse weakens that.
  - **Orchestrator-context cost.** `TaskList` output read into the permanent orchestrator context fights the scarcity discipline; a file summarized on demand is cheaper.

Net: the **artifact file remains the source of truth** for the DAG + state machine (it is the auditable plan→run handoff, supports a rich state set, and is summary-sized in the orchestrator). Optionally *mirror* a coarse status into `TaskList` for the operator's at-a-glance view, treating it as a read-only projection — never the authority.

---

## Caveats

- **Source-access caveat:** Nearly all academic sources (arXiv, OpenReview, ACL, emergentmind) returned HTTP 403 to direct fetch in the dev container; verification rested on WebSearch verbatim extractions (often triangulated across 2+ independent retrievals) plus, where available, official code repos (ROMA, ADaPT GitHub) and on-disk ground truth (the `~/.claude/tasks/` store was inspected directly). Confidence is high where code/filesystem corroborated, slightly lower where only search extraction was available.
- **Resumability mismatch in sources:** GAP and TRIAGE assume a single resumable agent; their *artifacts* (topological DAG, prospective plan) transfer, but their *runtime loops* do not. TDP and ROMA assume co-running roles with runtime DAG mutation (Self-Revision); we replace that mutation with orchestrator-mediated re-spawn. No source models fire-and-return artifact-relay exactly — the relay mapping (R1, R6) is the synthesis's own bridge, well-grounded but not a paper claim.
- **Time-sensitivity:** the harness Task primitives are fast-moving (TodoWrite→Task migration at 0.3.142/v2.1.142; depth-5 spawn cap at v2.1.172, 2026-06-10; open bugs #29751/#20243). The brief's "unused primitive" framing is already stale. Re-verify the Task store's persistence/hygiene behavior before depending on it.
- **Confidence split:** R6 (structural-hazard mapping) and R7 (refuted finer-grained allocation claim) and the `~/.claude/tasks` non-reconciliation are medium/split-vote; treat as well-reasoned design guidance rather than settled fact.

## Open questions

1. **Cross-session DAG persistence:** Is there a supported way to make the harness Task store a *shared* plan→run handoff object (not session-UUID-scoped), or is a repo/journal file strictly necessary? (Bears on whether the "thin mirror" recommendation is even worth it.)
2. **Systemic-vs-local blocker signal:** Beyond DAG fan-out, what runtime signal best distinguishes a local blocker from a systemic one — e.g., does a verification-criterion failure (vs. an execution failure) warrant a different halt-scope? MAST separates them but does not prescribe halt-scope.
3. **Budget feedback loop:** Given our orchestrator *does* see per-worker returns (refuting pure ex-ante allocation), what is the right re-prioritization cadence — re-rank ready tasks every return, every level, or only on a budget-threshold breach?
4. **Verification cost accounting:** R4 mandates a verification step per `done` transition; under a finite token budget (R7), how should verification compute be budgeted separately from work compute, given verification is itself a separately-failing concern (MAST)?

---

## Addendum (2026-06-19) — live resumability finding (changes the keystone)

The report's keystone assumption — workers are **fire-and-return** — is now **conditionally false**: with the experimental flag `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` ON, subagents are **resumable**. Live-probed: an agent picked a number, paused mid-task with a question, was resumed via `SendMessage`, and correctly recalled its pre-pause number — proving native **mid-task escalate→resume with context intact**. (The pre-investigation's "#35240 broken" claim did not reproduce; the live probe superseded it.)

**Implication for the recommendations:** R1/R3/R6 (the artifact-relay built to *simulate* continuation) gain a native alternative — a long-lived executor that escalates to the orchestrator and resumes, rather than fresh-spawn-and-rehydrate.

**But resumability is not a free replacement — it moves the context problem.** An ephemeral relay worker's context dies on return (bounded); a *resumable* executor is long-lived, so its own context **accumulates across the whole workstream** — reintroducing bloat exactly on the ballooning workstreams P4/R8 warn about. Therefore the v2 architecture is a **HYBRID**: resumable-executor *for escalation* (short pause, bounded), but the executor *still delegates heavy work* to ephemeral sub-workers (its own context stays decision-level), and the **artifact file remains the durable, auditable source of truth**.

**The artifact file's two purposes — and why resumability doesn't retire it:** the executor-written file always did two distinct jobs — (1) keep the orchestrator lean (executor returns a decision-relevant summary; full detail → file; incremental disclosure), and (2) hand off context to a *next* subagent (the relay). Resumability supersedes only part of (2): same-executor continuation now uses native context instead of fresh-spawn-and-rehydrate. The file stays because (1) is unaffected, because the file is the **durable audit / source of truth** (in-context memory isn't auditable and is at risk from compaction/restart), and because it is the **fallback that makes depending on resumption safe** (a resumed agent that loses context can be replaced by a fresh one rehydrating from the file). Resumption = continuation; file = leanness + durability + backstop. Complementary, not competing. (v2 should state this dual purpose explicitly in `/auto-run` — currently it's split across two sections, never unified.)

**Durability — partially probed 2026-06-19:** multi-cycle retention CONFIRMED (a running-total accumulator stayed correct across 3 consecutive `SendMessage` resume cycles: 7→20→120, each requiring recall of the prior total); context-growth rate is ~linear and small for light escalation messages (~100 tokens/cycle: 18.0k→18.1k→18.2k→18.3k). So the *resume mechanism itself is cheap* — bloat comes from the executor doing heavy work in its own context, which reinforces the hybrid (keep escalations light, delegate heavy work). Resume rehydrates from the agent's transcript. **Still unprobed:** survival across context *compaction* (the accumulator never grew large enough to compact), across a *main-session restart*, at *scale* (10s–100s of cycles), and under *concurrency* (multiple resumable executors). Status: experimental flag; core capability + multi-cycle retention proven; treat as a confirmed v2 architecture axis, not yet production-depended-upon.
