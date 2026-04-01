---
name: project-assess
description: Structured framework for project assessment. Defines evaluation dimensions, assessment checklist, output format, and discussion techniques for surfacing hidden assumptions in architecture reviews.
---

# Skill: Project Assessment

## When to Activate

- User asks for a project review, audit, or assessment
- User wants to verify that code matches stated design intent
- User has specific concerns about consistency, architecture, or drift
- User is preparing to onboard someone and wants documentation verified
- User asks "does this follow best practice?" or "what are we missing?"
- `/assess` command is invoked

## Assessment Dimensions

Evaluate each dimension. Skip dimensions that clearly don't apply to the scope.

### 1. Organization & Structure
- Is the directory layout self-evident at first glance?
- Are there orphaned, misplaced, or stale files?
- Is there clear separation of concerns between directories?
- Are naming conventions consistent across the project?

### 2. Policy & Convention Consistency
- Does the code follow rules stated in CLAUDE.md, rules files, or other policy docs?
- Are there violations of the project's own stated conventions?
- Are generated files actually generated (not hand-edited with drift)?
- Are there hardcoded values that should come from centralized config?
- Do all environments follow the same patterns, or is one treated as "special"?

### 3. Documentation Completeness
- Is every directory, script, and config file documented or self-evident?
- Are setup steps complete and copy-pasteable (not "exercise for the reader")?
- Do docs match current code? (stale docs are worse than no docs)
- Are non-obvious decisions documented with "why", not just "what"?

### 4. Onboarding & Ease of Use
- Can someone go from clone to working by following the docs?
- Are error messages and help text actionable?
- Are there friction points in common workflows (env switching, secret management)?
- Is the "happy path" obvious and the edge cases documented?

### 5. Configuration Centralization
- Is there a single source of truth for config?
- Can you change environments by swapping one config file (and nothing else)?
- Are there config values scattered across multiple files that should be derived?
- Are secrets consistently separated from non-secret config?

### 6. Security Model
- Are credentials kept out of version control?
- Is the principle of least privilege applied consistently?
- Are there defense-in-depth layers (not a single gate)?
- Are residual risks documented (not just what's protected)?

### 7. Intent Alignment
This is the most important dimension — it requires the user to state their intent.
- Does the code express the stated design philosophy?
- Where does implementation diverge from intent?
- Are divergences intentional trade-offs or accidental drift?
- If the user says "X should be true", is X actually true in the code?

## Output Structure

```markdown
# Assessment: [Topic]

## Your Concerns
[Address each user concern with specific evidence. File paths, line numbers,
concrete examples. For each, state clearly: aligned, misaligned, or partially
aligned with their stated intent. This section comes FIRST because the user
told you what matters most to them.]

## Hidden Dependencies & Assumptions
[Things the user didn't ask about but should know before making decisions.
Second-order effects. Implicit coupling. Things that will break silently
if they change X. This is where the assessment earns its value — the user
can find obvious issues themselves.]

## General Assessment
[Standard dimensions with findings. A clean dimension is one line:
"Organization: Clean, no issues." A dimension with findings gets a table:

| # | File | Issue | Severity |
|---|---|---|---|

Lead with findings, not ratings. If you must rate, put the rating after
the findings so it's justified, not presumed.]

## Open Questions
[Decisions that need user input. One per item. For each:
- What the decision is
- Why it matters (consequence of not deciding)
- Brief options (detailed pros/cons come in discussion phase)]
```

## Discussion Techniques

### Surfacing Hidden Assumptions

After presenting findings, actively look for these patterns:

| Pattern | What to check | Example |
|---|---|---|
| **Implicit shared state** | Components that seem independent but share a resource | Two environments sharing one database, one MinIO, one VNet |
| **Environment asymmetry** | One environment treated as "special" when intent says equal | Sandbox-specific playbooks, hardcoded env names |
| **Temporal coupling** | Things that must happen in order but the order isn't enforced | Config generation before container build before init |
| **Infrastructure assumptions** | Code that assumes a specific network topology or host layout | Squid allowlist baked at build time constraining env switching |
| **Blast radius gaps** | Changes that affect more than the intended scope | Overwriting shared files (`.envrc`, inventory) when switching envs |

### Driving Productive Decisions

**One at a time.** Never batch architectural decisions. Each one may change the context for the next.

**Structure each decision as:**
1. The decision (one sentence)
2. Why it matters (what breaks or degrades without deciding)
3. Options (2-3, with pros/cons and alignment note)
4. Your recommendation (if you have one, say why)

**When the user pushes back or asks to explore:** This is the signal that the decision matters. Go deeper. Present trade-offs you haven't mentioned. Consider what each option implies for other parts of the system. Don't rush to converge.

**After the user decides:** Immediately note what the decision implies for remaining open questions. Update the plan file.

### Avoiding Premature Convergence

- Don't propose fixes during the assessment phase — present findings, not solutions
- Don't ask "should I fix this?" — instead present the finding and let the user decide scope
- If the user asks to fix something mid-assessment: note it as a remediation item, continue assessment
- Separate "here's what's wrong" from "here's how to fix it"
- The assessment document should be useful even if no remediation follows

## Checklist: Before Concluding Assessment

- [ ] Every user concern addressed with evidence (not just acknowledged)
- [ ] At least one hidden dependency or assumption surfaced
- [ ] All relevant dimensions evaluated (even if briefly)
- [ ] Open questions listed for discussion
- [ ] No premature remediation blended into findings
- [ ] Decisions captured in plan file with reasoning and trade-offs
- [ ] Project-level decisions and user intent saved to memory
