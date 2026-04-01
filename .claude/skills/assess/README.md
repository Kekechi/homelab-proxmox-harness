# assess

Structured project assessment with discussion-driven architecture review. Evaluates organization, consistency, documentation, and intent alignment. Surfaces hidden assumptions before optional remediation.

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

### Examples

```
/assess Thorough project review. Concerns: (1) Is the MinIO bootstrap
consistent with our config centralization policy? (2) Are there hardcoded
values that should come from sandbox.yml?
Intent: all config comes from one YAML per environment, no env-specific
logic outside that file. Context: adding production environment soon.
```

```
/assess The skills and commands setup. Intent: clear separation between
user-invocable skills and auto-loaded reference skills. Are there overlaps
or skills that should have disable-model-invocation set?
```

## Workflow

1. **Explore** — parallel agents investigate the codebase, prioritizing your concerns
2. **Assess** — structured findings: your concerns first, then general dimensions
3. **Discuss** — one decision at a time via follow-up questions
4. **Remediate** (optional) — only after discussion concludes; you choose whether to proceed

## After Assessment

The assessment document in the plan file is the deliverable. If you proceed to remediation, verify with `make lint` when done.
