---
description: Structured project assessment. Evaluates organization, consistency, documentation, and intent alignment. Drives discussion to surface hidden assumptions before optional remediation.
allowed_tools: ["Read", "Grep", "Glob", "Bash", "Agent", "AskUserQuestion", "Write", "Edit"]
---

# /assess

Structured project assessment with discussion-driven architecture review.

## What This Command Does

Runs a 4-phase assessment workflow:

1. **Explore** — Parallel agents investigate the codebase, prioritizing user concerns
2. **Assess** — Structured findings: user concerns first, then general dimensions
3. **Discuss** — Surface hidden assumptions, probe trade-offs, make decisions one at a time
4. **Remediate** (optional) — Implement fixes only after discussion concludes

Read `project-assess/SKILL.md` for the full assessment framework, dimensions, and discussion techniques.

## Usage

```
/assess <what to assess + specific concerns + your design intent>
```

### What makes a good assessment prompt

A thin prompt ("assess my project") produces a shallow assessment. Include:

| Element | Why it matters | Example |
|---|---|---|
| **Scope** | What to assess — the whole project, a subsystem, a recent change? | "the config management pipeline" |
| **Concerns** | Things that feel off, specific doubts, consistency worries | "I think the bootstrap script contradicts our centralization policy" |
| **Intent** | What the code *should* express — your design philosophy | "all environments should be identical, just swap config" |
| **Context** | Why now — onboarding, scaling, pre-release, post-incident? | "preparing to add a staging environment" |

If the prompt is missing scope or intent, ask clarifying questions before exploring.

### Examples

```
/assess Thorough project review. Concerns: (1) Is auth middleware consistent
with our zero-trust policy? (2) Does test coverage hit critical paths?
Intent: every service independently deployable.
```

```
/assess The config management system. Intent: all env config comes from one
YAML per environment. Are there places we've drifted? Hardcoded values that
should be parameterized? Context: adding a staging environment next quarter.
```

## Workflow Detail

### Phase 1: Explore

Launch up to 3 Explore agents in parallel. Allocate agents based on the prompt:

- **Agent A** (always): Focus on user's specific concerns — trace code paths, find evidence for or against
- **Agent B** (always): Policy/convention consistency — check files against stated rules, find hardcoded values, spot drift
- **Agent C** (if scope is broad): General assessment — structure, docs, onboarding, security model

If the user has no specific concerns (general audit), split as: consistency + general + docs/onboarding.

### Phase 2: Assess

Write findings to a plan file. Follow the output structure in `project-assess/SKILL.md`.

**Key rules:**
- Address user concerns FIRST — they told you what they care about
- DO NOT lead with praise — lead with what matters
- Surface at least one hidden dependency the user didn't ask about
- Ratings are fine as summary, but findings are the point

### Phase 3: Discuss

- Present ONE decision or open question at a time via AskUserQuestion
- For architectural decisions: options, pros/cons, alignment with stated intent
- When the user pushes back or asks to explore: go deeper before converging
- After each decision: note implications for remaining questions
- Proactively surface second-order effects ("if we decide X, that also means Y")

### Phase 4: Remediate (checkpoint)

Do NOT blend remediation into assessment. After discussion concludes:
- Ask: "Assessment complete. Proceed to remediation, or stop here?"
- If yes: create tasks from the prioritized findings, implement, verify
- If no: the assessment document stands as the deliverable

## After Assessment

- Save project-level decisions and user design intent to memory
- The plan file serves as the assessment artifact
- If remediation was done, verify with the project's lint/test commands
