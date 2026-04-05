---
name: assess
description: Structured project assessment. Evaluates organization, consistency, documentation, and intent alignment. Drives discussion to surface hidden assumptions before optional remediation.
disable-model-invocation: false
model: opus
effort: high
---

# Skill: Project Assessment

Run a structured assessment of a project or subsystem, surface hidden assumptions, and drive one-decision-at-a-time discussion before any remediation.

## When to Activate

- User asks for a project review, audit, or assessment
- User wants to verify that code matches stated design intent
- User has specific concerns about consistency, architecture, or drift
- User is preparing to onboard someone or wants documentation verified
- User asks "does this follow best practice?" or "what are we missing?"

## Phase 1: Explore

Think hard about hidden assumptions and second-order effects before launching agents.

If the prompt is missing scope or intent, ask clarifying questions before exploring.

Launch up to 3 Explore agents in parallel. Allocate based on the prompt:

- **Agent A** (always): Focus on user's specific concerns — trace code paths, find evidence for or against
- **Agent B** (always): Policy/convention consistency — check files against stated rules, find hardcoded values, spot drift
- **Agent C** (if scope is broad): General assessment — structure, docs, onboarding, security model

If no specific concerns (general audit), split as: consistency + general + docs/onboarding.

## Phase 2: Assess

Write findings to a plan file. Use the output structure below.

**Key rules:**
- Address user concerns FIRST — they told you what matters most
- Do not lead with praise — lead with what matters
- Surface at least one hidden dependency the user didn't ask about
- Findings are the point, not ratings

### Output Structure

```markdown
# Assessment: [Topic]

## Your Concerns
[Address each concern with specific evidence: file paths, line numbers, examples.
State clearly: aligned / misaligned / partially aligned with stated intent.]

## Hidden Dependencies & Assumptions
[Things the user didn't ask about but should know. Second-order effects,
implicit coupling, things that break silently if they change X.]

## General Assessment
[Dimensions with findings. A clean dimension: "Organization: Clean, no issues."
A dimension with findings:
| # | File | Issue | Severity |
Lead with findings, not ratings.]

## Open Questions
[Decisions that need user input. One per item:
- The decision
- Why it matters
- Brief options (pros/cons in discussion phase)]
```

## Assessment Dimensions

Evaluate each dimension. Skip dimensions that clearly don't apply to scope.

**1. Organization & Structure** — layout self-evident, orphaned files, separation of concerns, naming consistency

**2. Policy & Convention Consistency** — code follows CLAUDE.md/rules, violations, generated-vs-hand-edited drift, hardcoded values, environment equality

**3. Documentation Completeness** — every dir/script/config documented or self-evident, setup steps copy-pasteable, docs match code, "why" documented

**4. Onboarding & Ease of Use** — clone-to-working possible, actionable error messages, friction points, happy path obvious

**5. Configuration Centralization** — single source of truth, swap one config for env switching, scattered config values, secrets separation

**6. Security Model** — credentials out of version control, least privilege, defense-in-depth, residual risks documented

**7. Intent Alignment** — code expresses stated philosophy, divergences intentional or drift, user intent reflected

## Phase 3: Discuss

Present ONE decision or open question at a time via AskUserQuestion.

**Structure each decision as:**
1. The decision (one sentence)
2. Why it matters (consequence of not deciding)
3. Options with pros/cons and alignment note
4. Recommendation (if you have one, say why)

**When the user pushes back:** Go deeper. Present trade-offs not yet mentioned. Don't rush to converge.

**After the user decides:** Note implications for remaining open questions. Update the plan file.

**Patterns to surface actively:**

| Pattern | What to check |
|---|---|
| Implicit shared state | Components that seem independent but share a resource |
| Environment asymmetry | One environment treated as "special" when intent says equal |
| Temporal coupling | Things that must happen in order but order isn't enforced |
| Infrastructure assumptions | Code that assumes a specific network topology or host layout |
| Blast radius gaps | Changes that affect more than the intended scope |

**Avoid premature convergence:** Don't propose fixes during the assessment phase. Don't ask "should I fix this?" — present the finding and let the user decide scope.

## Phase 4: Remediate (checkpoint)

Do NOT blend remediation into assessment. After discussion concludes:
- Ask: "Assessment complete. Proceed to remediation, or stop here?"
- If yes: create tasks from the prioritized findings, implement, verify
- If no: the assessment document stands as the deliverable

## Before Concluding

- [ ] Every user concern addressed with evidence (not just acknowledged)
- [ ] At least one hidden dependency or assumption surfaced
- [ ] All relevant dimensions evaluated
- [ ] Open questions listed for discussion
- [ ] No premature remediation blended into findings
- [ ] Decisions captured in plan file with reasoning and trade-offs
- [ ] Project-level decisions and user intent saved to memory
