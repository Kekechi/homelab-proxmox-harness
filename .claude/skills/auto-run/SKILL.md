---
name: auto-run
description: Execute an autonomous long-running session under an /auto-plan autonomy contract. The main thread orchestrates only — execution and read-heavy diagnosis are delegated to subagents, each step is verified by its declared criterion, actions are bounded by the signed authorization manifest, and the run is journaled for asynchronous audit. Use for long unattended runs where real-time approval makes the operator the bottleneck.
disable-model-invocation: true
model: opus
effort: high
---

# Skill: Autonomous Session Execution

Drive a long, unattended run from a brief produced by `/auto-plan`. The operator has moved from real-time reviewer to **boundary-setter + asynchronous auditor**: they signed the contract up front and read the journal after, instead of approving each step.

The brief's **autonomy contract** is your operating authority. Its four clauses tell you everything the operator would otherwise tell you in real time:

| Clause | Tells you | Enforced in this skill by |
|---|---|---|
| **Authorization manifest** | what you may do | the authorization rule + stop condition 4 |
| **Verification criteria** | how each step proves it worked | the verification rule (per workstream) |
| **Stop conditions** | when to halt and return to the operator | the stop-condition list |
| **Journal protocol** | how to stay auditable without being watched | the journal + artifacts convention |

> **Governing principle — structural over instructional.** Prefer the *enforced* form of every rule over its *instructed* form. A long run's defining failure is that soft instructions ("return conclusions, not dumps") decay as context fills. Where a mechanism can enforce a rule — a Workflow schema return, a deny rule, absent credentials — use it. Prose is the fallback for what can't yet be enforced.

## When to activate

- A `/auto-plan` brief exists at `docs/design/<topic>.md` with a complete §2 autonomy contract.
- The operator has confirmed the §3 prerequisites (live-verified) and the manifest's Forbidden rails are active.

If no brief exists, or its contract is incomplete (no manifest / a workstream missing its verification criterion), **stop and run `/auto-plan`**. Do not improvise authority.

## Pre-flight gate (confirm before the first action)

1. **Brief loaded** — read it; restate objective, workstreams, and sequencing into the journal.
2. **Manifest internalized** — restate the authorization manifest into the journal; it governs every later action.
3. **Prerequisites in place** — §3 items done and verified live (e.g. fallback resolver failover tested). Any unconfirmed → halt and ask.
4. **Rails active** — deny rules for the manifest's Forbidden classes present; `.gitignore`/lint cover secrets + topology. Confirm, don't assume.

## The two roles

- **Main thread = orchestrator.** Holds **only** the objective, the manifest, decisions, and the journal — nothing else. It **routes pointers, not payloads**, and does not execute *or diagnose* in its own context.
- **Subagents = execution AND diagnosis.** Each does the heavy work — running deploys/loops, *and* the read-heavy diagnosis (reading configs, curling endpoints, querying APIs) — in its own ephemeral context, writes detail to an artifact file, and returns a decision-relevant summary + path.

> **Every byte the main thread reads is permanent.** The sharpest rule of a long run, and the easiest to lose: if a question's answer can come back as a sentence, it must come from a subagent — not from you reading the file. "Delegate execution" is *not enough*. A prior run delegated execution but ran the *diagnosis* inline (reading `run.sh`/`tls.yml` in full, curling endpoints, querying the Proxmox API) and that is where it burned the most context. The orchestrator's context is the scarce resource — delegate the reads, keep only the conclusions.

## Journal + artifacts (clause 4 in action)

- **Journal** — `.claude/session/<topic>-journal.md`, append-only, main thread. Holds the objective (re-read after any context summarization to fight goal drift), decisions + why, the **actively-maintained open-decisions ledger** (each entry closed or carried forward every time the journal is touched), and the step ledger (`step → outcome → artifact link`). This is the operator's async audit surface — point them here instead of asking them to watch.
- **Artifacts** — `.claude/session/artifacts/<topic>/<NN>-<step>.md`, written by subagents: full logs, output, code, reasoning. Makes aggressive summarization *safe* — recovery is a cheap `grep`, not a re-run.

## The subagent return contract

Every execution/investigation subagent returns ONLY this — decision-relevant, never so thin it forces **blind forwarding** (routing off a summary too sparse to be a real decision):

```
{
  outcome:          pass | fail | blocked,
  step:             <name>,
  what_happened:    one line,
  root_cause:       one line, tagged Known | Hypothesised (+ how to verify if Hypothesised),
  layer:            infra / role / app / config / ...,
  recommended_next: fix | retry | stop | escalate,
  verbatim_error:   <= 30 lines, ONLY when the literal text is the answer,
  verify_result:    <criterion + result> | null,
  artifact_path:    path to the full-detail artifact
}
```

Enforce structurally via a Workflow `schema` where the flow is deterministic; instruct it only for one-off hand-routed steps.

## Orchestration rules

- **Delegate execution *and* diagnosis.** Never run a long deploy/loop/audit, *or a read-heavy diagnosis*, in the main thread (see the principle above). `run_in_background` is not the fix for execution noise — *not doing it in the main thread* is.
- **Wait on long ops via a harness-tracked background job.** When the orchestrator must wait on a multi-minute op (loop / rebuild / deploy), launch it with `run_in_background` (optionally a `; echo SENTINEL rc=$?` tail) so the harness fires a real completion notification on exit. **Never** hand-roll `nohup … &` + `while kill -0 $PID` polling — a finished process becomes a zombie that `kill -0` reports alive *forever*, so the notification never fires and the operator has to babysit ("did it finish?" × 3). Subagents don't rescue this: one that backgrounds work and parks is never re-woken, so either it foreground-waits or the orchestrator owns the tracked job.
- **Detail flows agent → file → agent.** On an issue, the orchestrator decides **from the returned summary** and passes the `artifact_path` to the next subagent. *Reading the artifact file into the main thread is the failure mode* — it re-imports the bulk you delegated away. If you find yourself needing to read it often, the return contract is too thin (the mirror of blind-forwarding); fix the summary, or delegate the read.
- **Keep investigate + fix in one agent when coupled.** Split only when the fix is an independent unit — a cold fixer re-deriving the investigator's model is the re-derivation tax to avoid.
- **Expect recursive-harness workstreams to balloon.** When a workstream repairs the very harness the run verifies against (brief-flagged), expect expansion — one prior "wire the gate" task uncovered 6 latent cold-start bugs. Budget for it; don't mistake the expansion for scope-creep to halt on.
- **Deterministic flow → Workflow; exploratory flow → hand-route.** Encode known sequences as a `pipeline()` so routing is code and costs the main thread nothing. Hand-route only when the next step can't be known until the result is seen — and back every routing decision with a decision-relevant return.

## Authorization rule (clause 1 in action)

Before any consequential action, check its class against the manifest:
- **Authorized** (within its scope limit) → proceed.
- **Confirm-at-runtime** → halt and ask, even though authorized in principle.
- **Not on the manifest, or Forbidden** → halt and ask. Never self-extend authority.

**Scope-change handling:** new *work* discovered mid-run that is within the authorized actions **and** serves the objective **and** is verifiable → absorb it and journal it (the journal is what makes this safe). New work needing an un-authorized action, or shifting the objective → trip a stop condition. The plan's task list is a forecast; the manifest is the cage.

## Verification (clause 2 in action)

No step is "done" until **its declared criterion** passes — read the criterion from the workstream, don't assume one. Record it in `verify_result`.
- idempotency re-run (`changed=0`) · named test(s) · golden-output match · health check (`make verify-all` / per-service behavioral verifies / `/sanity-sweep` Tier-2)
- **Cold-start / first-boot criteria verify only on a full fresh rebuild** — never a phase-resume against already-settled hosts. A prior run got a false "fixed" on an apt-lock fix by re-running `--from deploy` while the lock was already free; that criterion was only truly verifiable from a cold boot.

The agent proves to itself the step worked, so the operator doesn't have to. And never build verified work on an **unverified harness**: verify the loop/tooling before you depend on it, and re-verify it the moment you change it — an unverified harness makes every downstream failure ambiguous (is it the fix, or the broken harness?).

## Stop conditions (clause 3 in action)

Halt → journal → escalate the *specific* decision on any of the brief's enumerated tripwires. The general set:
1. Second workaround at the same layer (wrong-layer fix).
2. The **objective's** verification fails twice with the same root cause.
3. A verification criterion fails with no root-cause hypothesis.
4. An action not **Authorized** on the manifest (or **Confirm-at-runtime**).
5. New work that shifts the objective.
6. Any session-specific tripwire from the brief (budget, no-progress, domain-specific).

**Halt scope — not every stop condition halts the whole run.** Match the scope of the halt to the scope of the problem:
- **Orthogonal** — a recurring failure that blocks nothing here → journal it as a separate backlog finding, route it to its own workstream, continue.
- **Blocks this workstream** (e.g. an apt-lock race that stops the cold rebuild a workstream is verified by) → **shelve this workstream and its dependents** (journal them blocked), **continue the independent workstreams**, and escalate the blocker — immediately if it's on the critical path, otherwise at a natural boundary. Frame it as "can't verify X because Y blocks it; Y needs its own fix" — a verification-blocker, not timidity. Never push past it and call X verified.
- **Systemic** — a boundary-crossing action, a wrong-layer-workaround signal, or a failure implicating shared foundations → halt the whole run and escalate.

*Caveat:* deciding which workstreams are "independent" of a blocker requires the brief's inter-workstream **dependency graph**. Until that's explicit (loose dependency *order* is not enough), be conservative — when independence is unclear, treat a blocker as run-halting rather than risk building on a broken foundation.

## Checkpoint commits

Commit at each verified fix (a clean unit for review + rollback). **Never `git push`** — the operator reviews history and pushes. Every commit obeys public-repo hygiene: no `.envrc`, `config/*.yml`, secrets, or topology.

## Closing the run

On completion or a stop-condition halt:
- Bring the journal current — close or carry every open-decisions entry.
- Summarize for the operator: what completed and was verified (by which criterion), what halted and why, the commit range to review, any step verified by idempotency only where a health check would be stronger, and **any written claim this run invalidated** (docs/skills now needing an update).
- Hand back: "History at `<range>`, journal at `.claude/session/<topic>-journal.md`. Review and push when ready."

## How to prompt this skill

> "Execute `docs/design/<topic>.md` autonomously under its autonomy contract. You orchestrate only — delegate every execution step to a subagent that writes detail to a file and returns the decision-relevant contract; route pointers, not payloads. Bound every action by the authorization manifest; verify each workstream by its declared criterion; journal decisions and outcomes; commit verified fixes, never push. Halt and ask me on the stop conditions."
