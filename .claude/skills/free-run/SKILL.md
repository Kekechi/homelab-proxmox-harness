---
name: free-run
description: Execute an agreed design record autonomously in sandbox — direct main-thread execution with a lightweight journal, per-slice commits, and behavioral verification. The approved design record is the authority; there is no orchestration ceremony.
disable-model-invocation: true
---

# Skill: Free-Run Execution

Execute an operator-agreed design record (`docs/design/<topic>.md`) directly. "Looks
good is a go": the record carries the scope and the safety boundary; these habits keep
the run auditable without hooks, manifests, or subagent pipelines. Sandbox is cheap to
revert — operational failures are wanted input for the next harness iteration, not
reasons to stop.

## Preconditions

- A design record exists and the operator has agreed to it. No record → run `/design`
  first; never improvise scope.
- If the record has an **Execution boundary** section, restate it in the journal before
  the first action. If it doesn't, the non-negotiables below are the boundary.

## Non-negotiables (regardless of what the record says)

- Plan file before every `terraform apply`; applies target sandbox only — production is
  plan-only + `/handoff`
- No secrets in tree; public-repo scrub on every commit (no internal IPs, hostnames,
  domains, or security-product names)
- No state surgery (`state rm|mv`, `import`, `force-unlock`) without operator approval
- Never `git push` — the operator reviews history and pushes

## Execution habits

- **Work in the main thread.** Delegate to subagents only when it clearly pays (bulk
  mechanical sweeps, isolated read-heavy audits) — not as a default posture.
- **Journal as you go** — `session/<topic>-journal.md`, append-only: decisions
  and why, failures with root cause tagged **Known** / **Hypothesised**, scope absorbed
  or deferred. Journal operational failures as lessons and keep moving.
- **Commit per coherent slice**, at a verified state, passing the constraints checklist
  in CLAUDE.md.
- **Wait on long operations via harness-tracked background jobs** (`run_in_background`) —
  never hand-rolled `nohup … &` + PID polling; a reaped process polls as alive forever
  and the completion signal never fires.

## Verification

A step is done when its behavioral check passes, not when the tool exits 0:

- `make verify-<component>` for the touched component; `make verify-all` as the closing gate
- Generator/config changes: `scripts/test-golden.py` (review any baseline diff)
- Idempotency: re-run the play — second run reports `changed=0`
- Cold-start / first-boot criteria verify only on a genuinely fresh rebuild (the
  destroy→rebuild loop), never a warm re-run against settled hosts
- Deeper smell check when warranted: `/sanity-sweep` (Tier-2, record-only)

## Stop and ask only when

1. The next step needs an action outside the record's boundary or the non-negotiables
2. The same fix has failed twice at the same layer with the same root cause — you're
   probably fixing the wrong layer
3. Newly discovered work would shift the objective (absorbing in-scope discovered work
   is fine — journal it)

Everything else — including verification failures you have a hypothesis for — is yours
to handle.

## Closing

- Bring the journal current, then summarize: what shipped and how it was verified, what
  was deferred, lessons journaled, and the commit range to review.
- Hand back: "History at `<range>`, journal at `session/<topic>-journal.md`.
  Review and push when ready."
- Offer `/retro` when the session surfaced lessons worth keeping.
