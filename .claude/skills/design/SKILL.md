---
name: design
description: Design exploration for net-new infrastructure. Facilitates one-decision-at-a-time discussion to reach a clear design record before any planning or implementation begins.
disable-model-invocation: false
model: opus
effort: high
---

# Skill: Design Exploration

Facilitate a structured design discussion for net-new infrastructure. The goal is a clear, agreed design record — not a plan, not code.

## When to Activate

- User has a rough idea but hasn't decided what to build yet
- User wants to think through architecture before committing to an approach
- User says "brainstorm", "design exploration", "not implementing yet", or similar
- The idea is too vague to hand to `/infra-plan` without design decisions first

## When NOT to Activate

- User already knows what they want to build → use `/infra-plan` directly
- User wants to evaluate existing infrastructure → use `/assess`

## Session Document

Design sessions are long. At the end of Phase 1 and after every decision in Phase 2, write (or update) a session document at:

```
.claude/session/design-<topic-slug>.md
```

This document is the source of truth for the session. If context is compacted or cleared, the user re-invokes `/design` with this file as context and nothing is lost.

**Format:**

```markdown
# Design Session: [Topic]
Status: In Progress | Phase: [Orient / Explore / Audit / Complete]
Resume: run `/design` and reference this file as context
Last decision: [brief label]

## Scope & Boundaries
In scope: ...
Deferred (not forgotten): ...

## Decision Axes
1. ...
2. ...

## Research Findings
### [Topic]
- **Known** (from official docs / direct observation, [URL if available]): ...
- **Inferred** (from training knowledge / community sources — verify before acting): ...

## Decisions Made
| # | Decision | Choice | Rationale | Evidence basis |
|---|---|---|---|---|
| 1 | ... | ... | ... | Known / Inferred |

## In Consideration
| Decision | Options on the table | Current lean |
|---|---|---|

## Audit Results (Phase 3)
Unvalidated assumptions: ...
Missing decisions: ...
Likely fine, worth confirming: ...

## Open Items (deferred)
...
```

**Known vs Inferred rule:** anything from official docs, a live test, or a direct API/config observation is **Known**. Anything from training knowledge, community posts, or reasoning from general principles is **Inferred**. Never promote an inferred finding to Known without a citation or live verification. This mirrors the repo's debugging discipline in CLAUDE.md.

**When to write/update the session document:**
- End of Phase 1: write the initial doc (scope, axes)
- After each Phase 2 decision: update Decisions Made, In Consideration, and Research Findings
- After Phase 3 audit: update Audit Results
- Phase 4: the session doc becomes the source for the final design record

## Context Reset Guidance

After writing the session document, if the conversation has grown long (post Phase 1, or after 3+ decisions), say:

> "SESSION.md is up to date at `.claude/session/design-<topic>.md`. If context is getting long, run `/clear` now — then re-invoke `/design` with: 'Continue from `.claude/session/design-<topic>.md`.' Everything needed to resume is in that file."

Do not say this after every single decision — only when it would be genuinely useful (context is long, or a natural phase boundary has just passed).

## Pre-flight: Squid allowlist check

Before starting any design session involving new software, check whether that software's documentation domain is in the Squid allowed-domains list:

```bash
grep "<software-domain>" /workspace/.devcontainer/squid/squid.conf
```

If the domain is missing, ask the operator to add it **now** — before design begins. Doc verification is needed throughout design, plan review, and deployment. Discovering a blocked domain mid-session wastes time and breaks the research flow. Relevant domains to check: official docs, vendor package repos (e.g. `repo.powerdns.com`), and any GitHub raw content sources.

## Phase 1: Orient

Before asking anything, do three things:

1. **Check if the goal is clear enough** — if the technology and rough purpose are stated, that's enough to start. Don't demand a fully-formed spec. If a prior document is provided as context, treat it as a brainstorm: surface its claims as assumptions to evaluate, not as decisions already made.
2. **Identify the key decision axes** — what are the 3-5 design dimensions that will shape this infrastructure? (e.g., topology, network placement, operations, security, extensibility)
3. **Flag any false constraints** — if the user has stated a blocker, ask yourself: is it real? Name it early if it isn't.

State the decision axes to the user upfront so the session feels structured, not open-ended.

4. **Establish scope boundaries** — identify what is adjacent to this design and explicitly defer it. Design one layer at a time: if this session is about infrastructure, defer software deployment decisions; if it's about software deployment, defer consumer-side integration. The order isn't fixed — sometimes software architecture must be sketched first to know what infrastructure to provision (e.g., "one-tier or two-tier?" determines "one host or two?"). What matters is not mixing both layers mid-session. Name the deferred layer explicitly so the user knows it's deferred, not forgotten.

**After Phase 1:** write the session document with scope and decision axes. Offer the context reset if the conversation already has significant prior context.

## Phase 2: Explore decisions one layer at a time

Work through decision axes in dependency order — don't discuss sizing before topology, don't discuss DNS before network placement.

**For each decision:**
1. State what you know and what you're assuming
2. Present the relevant options with honest tradeoffs
3. Include the industry reference point when it's meaningfully different from homelab practice
4. **When the decision involves choosing between software options, run two research rounds before recommending:**
   - **Round 1 — community/ecosystem research:** What do practitioners actually use? What is the community sentiment? What tooling ecosystem has formed around each option? Training knowledge produces a reasonable shortlist; community research validates it and surfaces what training knowledge misses (emerging tools, real adoption patterns, integration ecosystems).
   - **Round 2 — official documentation research:** What does the vendor recommend for topology, deployment, and configuration? Ground the architecture in official guidance before proposing it. Don't propose a specific topology based on training knowledge alone — a single detail (e.g., the official migration guide showing two components colocated by default) can change the design.
   - Don't skip Round 2 even when Round 1 confirms the recommendation. Community research validates the choice; official docs validate the architecture.
   - **Before recording the software decision, extract hard constraints from official docs:** minimum system requirements (RAM, disk, CPU), version floors for specific features, supported configuration mechanisms (env vars vs config files vs flags), default ports, and the vendor's recommended TLS/reverse-proxy topology. Cross-check any community-sourced values for these (e.g. "runs fine on 4GB with tuning") against documented minimums — community experience is unreliable for hard floors. Do not defer this to a post-design audit; sizing and configuration constraints discovered after the design record is written require rework.
5. **Verify against official documentation** — if the recommendation depends on how a specific tool behaves or what a vendor recommends, check the official docs before presenting it. Distinguish "this is from training knowledge" from "this is what the docs say." If docs are unreachable, say so explicitly rather than presenting training knowledge as authoritative.
5. **Test against a live instance if one is available** — if the user has a running (even broken) sandbox with the target software, test CLI flags and initialization paths live during design. Don't carry forward an assumption about how a command behaves when it can be verified directly. Catching a wrong flag mapping or initialization flow during design is far cheaper than debugging it after code is written. If the user hasn't mentioned whether a sandbox exists, ask.
6. **Frame configuration methods to match the tool's deployment model** — if the tool's standalone/self-hosted mode is designed around a config file, present config-file editing as the native approach, not a workaround. "Edit ca.json" and "edit nginx.conf" are native operations. Framing them as "hand-editing" or inferior to a CLI implies they're fallbacks, which triggers unnecessary exploration of alternative interfaces. Reserve API/CLI framing for deployment modes where those are the primary interface.
7. Make a recommendation if you have one — say why
7. Wait for the user to decide before moving on

**After each decision:** update the session document — add a row to Decisions Made (with Evidence basis: Known/Inferred), update In Consideration with the next open question, and record any research findings. Offer the context reset at natural pauses (every 3 decisions, or after a research-heavy decision).

**Rules:**
- One decision at a time. Do not bundle multiple open questions in a single turn.
- When the user pushes back, go deeper — present tradeoffs not yet mentioned. Don't rush to converge.
- When the user corrects an assumption, accept it and update the design. Don't defend the assumption.
- Surface extensibility paths without over-engineering: "this doesn't require infra changes, just a config update later" is a valid and useful answer.

**Patterns to watch for:**

| Pattern | What to do |
|---|---|
| False constraint | Name it and dissolve it before it blocks the design |
| Chicken-and-egg | Identify the actual dependency order — often it's not circular |
| Environment asymmetry | Note when sandbox and production designs diverge and whether that's intentional |
| Operational debt | Flag complexity that feels clever now but will hurt during incidents |
| Premature extensibility | Call it out — design for what's needed, note the extension path |
| Prior document bias | Treat any context document (brainstorm, prior design, session notes) as unvalidated input — no decision in it is locked. Challenge claims with the same rigor as new proposals. Committed docs (finalized design records) are different; brainstorms and hackpad notes are not. |

## Phase 3: Audit

Before declaring the design ready, run an explicit audit. Present these to the user:

**Unvalidated assumptions** — things you assumed that the user hasn't confirmed (network topology, software capabilities, existing services)

**Missing decisions** — anything that needs to be decided before planning can start (sizing, OS, naming conventions, secret management)

**Likely fine, worth confirming** — lower-stakes items the user can nod at or correct quickly

Don't skip this phase. It's where the most useful corrections happen.

**After Phase 3:** update the session document Audit Results section.

## Phase 4: Design Record

Once the user confirms the design is ready, produce a concise design record:

```markdown
# Design: [Topic]

## Goal
One paragraph: what this infrastructure does and why.

## Design Decisions
| Decision | Choice | Rationale |
|---|---|---|
| ... | ... | ... |

## Component Summary
[Table or diagram of components, types, placement, always-on vs. normally-off]

## Open Items (deferred, not forgotten)
[Things intentionally deferred with a note on when/how to revisit]

## Ready for planning
[Explicit statement that design is complete and what to hand to /infra-plan]
```

Save this as `docs/design/<topic>.md` (committed). The session document at `.claude/session/design-<topic>.md` is not committed — it's session state that can be discarded once the design record is written.

## Handoff

When the user is ready, say:
> "Run `/infra-plan` with this design as the input."

Do not launch `/infra-plan` automatically. The user decides when to cross from design to planning.

## Tone and Pacing

- Lead with concerns and constraints, not enthusiasm
- Keep individual turns short — one question or one recommendation at a time
- When you don't know something (software capability, industry practice), say so rather than guessing
- The session is successful when the user has made decisions, not when you have produced output

## How to prompt this skill

If the user asks how to start a design session in the future:

> "I want to explore [technology/system] for [rough goal]. I haven't decided what to build yet. Help me think through the design — challenge my assumptions, surface what I haven't considered, and ask focused questions one at a time. Don't plan or implement until I say I'm ready."

Key signals: *"challenge my assumptions"*, *"one at a time"*, *"don't plan until I say ready"*
