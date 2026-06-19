---
name: auto-plan
description: Plan an autonomous long-running session. Harvests the backlog (docs, session records, memories), triages readiness, selects scope, then produces the autonomy contract — authorization manifest, per-workstream verification criteria, stop conditions, journal protocol — as an executable brief that /auto-run consumes. Use before handing the agent a long unattended run.
disable-model-invocation: true
model: opus
effort: high
---

# Skill: Autonomous Session Planning (Pre-flight)

Turn "what should the next autonomous session do?" into an executable brief with a complete **autonomy contract**. Planning is a funnel: **discover the backlog → triage → select scope → build the contract.** The deliverable is a brief written to the executing agent (`/auto-run`).

The reference output shape is `docs/design/deployment-automation-overhaul.md` — but treat its rebuild-loop, MinIO, and resolver specifics as *one instance*, not the template. This skill is general.

## Why this skill exists — the autonomy contract

A human stays in the loop for five jobs. Four can be pre-declared; the fifth can't, and is what the others escalate to:

| Operator's real-time job | Clause that retires it | This skill's output |
|---|---|---|
| Approve each consequential action | **Authorization manifest** | derived from the action inventory, operator-signed |
| Check each step actually worked | **Verification criterion** | one per workstream |
| Catch wrong turns / thrash / drift | **Stop conditions** | enumerated tripwires |
| Watch progress, stay available | **Journal protocol** | named file + ledger discipline |
| Supply genuinely novel judgment | *(irreducible)* | stop conditions escalate to it |

Make clauses 1–4 complete enough that the run only returns to the operator for the genuinely novel — and hands them the *specific* decision, not the whole run. **The plan's task list is a forecast; the manifest is the cage.** (Validated against a real session — see the case study in `.claude/session/autonomous-session-policy-draft-2026-06-17.md`. Clauses the prior session lacked — stop conditions, journal — mapped onto its failures, so both are first-class outputs here.)

## The working file (load-bearing — read this before anything)

Planning runs long and threads get dropped. Keep `.claude/session/auto-plan-<topic>.md` alive **from turn one**, not written at the end. This is *structural-over-instructional applied to working memory*: relying on either party to "remember that thing" decays; writing it down the moment it's said does not. The operator should never have to be your memory.

**Sections:**
- **Backlog candidates** — every task in play, each with its readiness assessment (Phase 1).
- **Gating prerequisites** — things that must happen before the brief is ready (e.g. "apt-fallback → `/design` first"). Each marked `done` / `tracked-elsewhere` / `blocking`. *This section exists because a decided-but-not-yet-done prerequisite once evaporated — it was settled, so it wasn't an "open decision," and it was blocking, so it wasn't just backlog. It had no slot and got dropped.*
- **Open decisions** — unresolved, carried forward.
- **Decisions made** — with rationale.

**Two rules:**
1. **Capture on mention, not on decision.** The moment *either party* says "we should do X" / "X before the run" / "that needs design," it goes in the file *that turn*. **Silence isn't dismissal** — when you raise something and the operator moves on without acknowledging it (they're already thinking about the next task), capture it anyway. Items leave the file only by an *explicit* decision, never by going unmentioned.
2. **Brief-readiness is gated on gating-prerequisites being clear.** Phase 2's "write the brief" step cannot complete while any gating prerequisite is still `blocking`.

Keep the ledger actively maintained: each entry closed with its resolution or carried forward explicitly every time the file is touched.

## When to activate / not

- **Activate:** the operator wants the agent to drive multi-step work with minimal supervision — including the open "what's next?" framing, which is a valid start (the objective crystallizes at selection, it need not be given up front).
- **Don't:** a single well-scoped change → `/infra-plan` or a `*-deploy` pipeline; the agent should stop for approval at each step → the normal pipelines.

---

## Phase 1 — Scope (backlog → committed scope)

### 1.1 Harvest the backlog
Sweep every source where pending work hides; produce a deduplicated candidate list in the working file:
- design records' "Open items" (`docs/design/`, `docs/notes/`)
- session journals + retros (`.claude/session/`)
- memories with `OPEN` / `deferred` / `TODO` markers
- git loose ends (un-pushed commits, known flakes/blockers)

Delegate as a fan-out (one reader per source class, structural cap on returns). Close with a **completeness check** — "what *class* of backlog did we not sweep?" A missed item is a silent gap.

### 1.2 Assess readiness (per candidate)

| Dimension | Question | Consequence |
|---|---|---|
| **Design clarity** | ready, or design-shaped? | design-shaped → `/design` **prerequisite** (gating), never smuggled into the run |
| **What it touches** | one-line enumeration, *even if "straightforward"* | a "straightforward" label must not survive un-probed; hidden weight surfaces here, not mid-run |
| **Harness & tooling** | does the verification harness + verify target exist for it? | feeds the clause-2 criterion; missing harness → a "build it first" workstream or defer |
| **Permissions** | which consequential action classes? grantable? | feeds the manifest (2.4a) |
| **Harness relationship** | does it *depend on*, *mutate*, or *is it* the harness? | **mutate** = brick risk (a workstream flipping a default the loop relies on); **is the harness** = recursive, high-variance, expansion-prone — flag it |
| **Dependencies** | blocked by / must follow another item? | sequencing |
| **Staleness** | what written claim / doc does finishing this falsify? | spawn a dependent doc/SKILL-fix sub-task — kills stale docs structurally, not by cleverness |

### 1.3 Select the session scope
Operator decides the cut from the triaged list (one decision at a time). Then:
- Design-shaped items → route to `/design` as a gating prerequisite (recorded, blocking).
- Harness-not-ready items → add a "build the harness first" workstream, or defer.
- **Fix the objective** — it crystallizes here from the chosen scope.
- **Defer the rest with a destination** — write deferrals back to the design-record "Open Items" + a memory `deferred` marker so the next `/auto-plan` harvest finds them. The backlog compounds, it doesn't evaporate.

---

## Phase 2 — Contract (selected scope → executable brief)

### 2.1 Decompose into workstreams (dependency order)
Sequence so each unblocks the next. Name the discipline each needs — *refactor* vs *net-new design* vs *live-debug*. For any workstream flagged recursive-harness (1.2), note it is expansion-prone so the brief sets that expectation.

### 2.2 Investigate + live-verify load-bearing assumptions
Delegate recon (one layer, conclusions not dumps — prefer a Workflow schema return or write-to-file + summary; the soft "no dumps" instruction decays under load). Then **verify load-bearing assumptions on the real system** — the live test confirms; code reading only reinforces. Keep the `Known | Hypothesised` tag, on *your own* assumptions too, until verified.

### 2.3 Hunt session-bricking risks
Two distinct checks:
- **Dependency:** what does the loop depend on to keep running and recover? (a resolver it destroys; a state backend outside the thing being rebuilt).
- **Mutation:** does any selected workstream *change* the harness the run itself relies on? (flipping a fetch default to `fail` can brick every later cold rebuild). 
Verify the load-bearing ones live; list survivors as operator prerequisites.

### 2.4 Build the four-clause autonomy contract

**2.4a Authorization manifest (clause 1).** Walk the workstreams and enumerate every consequential action class. Deduplicate into an action inventory. For each, the operator marks **Authorized** (+ scope limit) / **Forbidden** / **Confirm-at-runtime**. Derived and signed, never volunteered or agent-guessed. Cross-reference enforcement tiers (where guardrails matter):

| Tier | Holds because | Guardrail |
|---|---|---|
| Environment-enforced | capability absent | none — free safety |
| Discipline-required | only policy forbids (no push, public-repo hygiene, state-bucket integrity) | **make structural** — deny rules from the Forbidden list |
| Relaxed | the Authorized set | none |

**Calibrate against intent — Confirm-at-runtime is a rare escape hatch.** Each Confirm-at-runtime entry is a place the run stops for the operator — the bottleneck this skill exists to remove. Treat every one as a *planning smell*: push it to **Authorized** (with a scope limit) or **Forbidden** at plan time. When the stated objective clearly covers an action, authorize it outright — don't make the run re-ask (a prior `--include-vms` full teardown sat in Confirm-at-runtime even though "full fresh deploy" plainly authorized it, costing repeated mid-run asks). If stakes warrant a single check, prefer **confirm-once-per-session, then Authorized** over confirm-every-time. Reserve true Confirm-at-runtime for actions that are *both* high-stakes *and* genuinely impossible to pre-decide.

**2.4b Verification criteria (clause 2).** For **each workstream**, declare the machine-checkable criterion that proves it worked — pick the model that fits, not a fixed default:
- deploy/config → idempotency re-run (`changed=0`)
- code/refactor → named test(s) pass
- generator/transform → golden-output match
- service → health check (`make verify-<svc>` / `make verify-all`, Tier-1 behavioral verifies, `/sanity-sweep` Tier-2)
- **cold-start / first-boot behavior → a full fresh rebuild only** (a phase-resume against settled hosts gives a false pass)

A workstream with no machine-checkable criterion is a planning gap to resolve now.

**2.4c Stop conditions (clause 3).** Enumerate the tripwires that halt the run and return the *specific* decision. General set + session-specific:
1. Second workaround at the same layer.
2. Same step fails twice with the same root cause.
3. A verification criterion fails with no root-cause hypothesis.
4. An action not **Authorized** on the manifest (or **Confirm-at-runtime**).
5. New work that shifts the **objective** (vs. within manifest + objective + verifiable → absorbed and journaled).
6. Session-specific (budget/time ceilings, no-progress counters).
Lift latent discipline from memory/CLAUDE.md into explicit tripwires — unwritten rules don't survive an unattended run.

**2.4d Journal protocol (clause 4).** Name the run journal (`.claude/session/<topic>-journal.md`); specify it holds the objective line, decisions + why, the open-decisions ledger, and a step ledger (`step → outcome → artifact link`).

### 2.5 Structural guardrails + write the brief
Turn the manifest's **Forbidden** entries into structural rails (a `Bash(git push:*)` deny rule beats "remember not to push"); prepare any `.devcontainer` change for the operator. Pre-clear the permission posture against the action inventory so the run doesn't thrash on denials. **Do not write the brief while any gating prerequisite is `blocking`.** Then write it.

## The brief (deliverable)

Write to `docs/design/<topic>.md` — committed, **intent-level only** (no IPs, domain, VLAN IDs, internal hostnames, product names; resolve from `config/<env>.yml` at runtime). Spine:

```markdown
# <Topic> — Session Brief
Status: planning complete, ready for execution
Objective: <one line>
(Work plan for an autonomous agent, not a design record. Cite file:line; no environment specifics.)

## 1. Operating model
## 2. Autonomy contract
### Authorization manifest   <action class → Authorized(scope) / Forbidden / Confirm-at-runtime>
### Stop conditions
### Journal protocol
## 3. Prerequisites (operator, before the session)   <session-bricking fixes, each verified live>
## 4. Workstreams (dependency order)   <WSn: approach / fix layer / authorized actions (⊆ manifest) / verification criterion / expansion-prone?>
## 5. Sequencing rationale
## 6. Open items   <deferred backlog, with destination>
```

Every workstream carries its slice of two clauses — **authorized actions** and **verification criterion**. A workstream missing either is not ready.

## Handoff

When the operator confirms the brief and all gating prerequisites are clear:
> "Run `/auto-run` with `docs/design/<topic>.md`. Confirm the §3 prerequisites are in place and the manifest's Forbidden rails are active first."

Do not start the run. The operator owns the §3 prerequisites and signs the manifest.

## Tone and pacing

- Lead with concerns; the value is in 1.2 and 2.2–2.3 (what the stated scope omits).
- One decision at a time in operator-facing steps. Mark Known vs Hypothesised; never promote without live verification.

## How to prompt this skill

> "Plan the next autonomous session. First harvest the backlog from docs, session records, and memories and check nothing's missed; triage each candidate for readiness (design-shaped? harness ready? what does it touch? does it mutate the loop?); help me select scope. Then build the autonomy contract — sign an authorization manifest, declare a verification criterion per workstream, enumerate stop conditions, set the journal protocol. Keep a live working file and capture anything either of us raises the moment it's said."
