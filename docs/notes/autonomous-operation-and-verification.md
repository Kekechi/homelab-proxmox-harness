# Autonomous Operation & Verification — Study Reference

**Captured:** 2026-06-17, from a working discussion while designing the `/auto-plan` + `/auto-run` skills.
**Status:** a springboard for deeper study, not a finished synthesis. The point is to have something to return to and think harder about when there's time.
**Note:** this lives in a public repo. The content is general CS/SRE theory plus intent-level self-reflection (no topology/secrets). Relocate to a local/uncommitted spot if the candid bits should stay private.

---

## 1. The framework we built (recap)

The **autonomy contract**: every reason a human stays in the loop maps to one pre-declarable artifact; what's left is the only thing that can't be pre-declared.

| Operator's real-time job | Pre-declared clause |
|---|---|
| Approve each consequential action | **Authorization manifest** (derived from the action inventory, operator-signed) |
| Check each step actually worked | **Verification criterion** (one per workstream) |
| Catch wrong turns / thrash / drift | **Stop conditions** (tripwires) |
| Watch progress, stay available | **Journal** (async audit surface) |
| Supply genuinely novel judgment | *(irreducible — stop conditions escalate to it)* |

Design goal: make clauses 1–4 complete enough that the irreducible-judgment surface shrinks to "the genuinely novel," and a tripped stop condition hands the operator the *specific* decision, not the whole run.

Implemented in `.claude/skills/auto-plan/` (produces the contract) and `.claude/skills/auto-run/` (executes under it). Rationale + case study in `.claude/session/autonomous-session-policy-draft-2026-06-17.md`.

---

## 2. Where it sits in the literature

This is well-trodden ground in **human-automation interaction**. The framework is mostly a re-derivation — worth knowing the originals.

- **Supervisory control** — *Thomas Sheridan, "Telerobotics, Automation, and Human Supervisory Control" (MIT Press, 1992).* The operational match. Human sets goals + constraints, automation executes, human monitors and intervenes *by exception* ("management by exception"). The whole design is a special case of this.
- **Design by Contract** — *Bertrand Meyer (Eiffel; "Object-Oriented Software Construction").* The structural match. The clauses map almost one-to-one:
  - authorization manifest ↔ **precondition** (what may run)
  - verification criterion ↔ **postcondition** (what must hold after)
  - stop condition ↔ **invariant** (whose violation aborts)
- **Levels / types of automation** — *Parasuraman, Sheridan & Wickens, "A Model for Types and Levels of Human Interaction with Automation," IEEE Trans. SMC (2000);* earlier *Sheridan & Verplank (1978).* Any function decomposes into acquisition → analysis → decision → action, each automatable to a *level* (1–10). The manifest is literally "set the level of automation per action class." See also **adaptive/adjustable automation**.
- **Ironies of Automation** — *Lisanne Bainbridge, Automatica (1983).* The essential caution. The more you automate, the more the human's residual role is *only the hardest cases*, and the human loses the context/practice to handle them (de-skilling). Our "irreducible judgment" residual is exactly that; the journal is only a partial mitigation.
- **Joint Cognitive Systems / automation surprises / the "substitution myth"** — *David Woods & Erik Hollnagel, "Joint Cognitive Systems" (2005/06).* Automating a task doesn't remove the human's work, it *transforms* it — design the human-automation *coordination*, not just the autonomy.

---

## 3. What's genuinely new (the frontier worth the deeper thought)

Two things break the classical frames — this is where study will actually pay off, because the textbooks give the least here:

1. **The actor is stochastic.** Supervisory control assumes the automation is *reliable within its envelope*. An LLM can fail in-distribution, unpredictably. So verification matters *more*, and stop conditions can never enumerate all failure modes → why "structural over instructional" and adversarial verification carry weight.
2. **The context window is finite working memory that degrades.** No classical-automation analog (a thermostat doesn't forget). The journal-as-offload is closer to **distributed cognition / external memory** (*Edwin Hutchins, "Cognition in the Wild"*) and **bounded rationality** (*Herbert Simon*) than to control theory.

---

## 4. Verification-first as the through-line

The verification + stop-condition clauses are the same principle at different altitudes:

> **TDD** (unit) → **ATDD / BDD** (feature) → **canary analysis / SLOs** (production) → **autonomy contract verification clause** (autonomous run).

Common rule: *define the mechanically-checkable success condition before you build; make "done" objective.*

Root, older than software — **"build quality in, don't inspect it in"** (*W. Edwards Deming*; Toyota Production System **jidoka** / autonomation). The **Andon cord** — anyone can halt the line on a defect — is the literal real-world stop condition.

---

## 5. The self-reflection (the actual learning)

The pattern: **strong on design and brainstorming, weak on confirming things actually work — fixing breakage as it surfaces** rather than verifying continuously.

- The **apt/TLS cold-start bug** is its signature: a cross-component ordering/integration failure that unit-level design *structurally cannot* catch — it only appears on a full from-scratch boot. Design rigor doesn't prevent it; an integration harness does.
- The **missing service health checks** are the same gap, named.

The encouraging half: the correction is **already in motion in this project.**
- The **destroy→rebuild loop is the CI** — the integration harness that surfaces exactly the bug class design misses.
- The health-check gap is now a **named clause** instead of an unspoken assumption.

The growth edge for the next few months: **generalize verify-first *before* failure, not after** — make "what's the machine-checkable success condition?" a reflex at design time, not a postmortem finding.

---

## 6. Reading list (for when there's time)

Foundational papers:
- Bainbridge, "Ironies of Automation" (1983) — short, start here.
- Parasuraman, Sheridan & Wickens, "A Model for Types and Levels of Human Interaction with Automation" (2000).
- Sheridan, *Telerobotics, Automation, and Human Supervisory Control* (1992).
- Woods & Hollnagel, *Joint Cognitive Systems* (2005) — automation surprises, substitution myth.

Software / contract:
- Meyer, *Object-Oriented Software Construction* — Design by Contract chapters.

Industrial practice (the big-tech harness the reflection points at):
- **Google SRE Book** — "Embracing Risk" (error budgets), "Service Level Objectives," "Eliminating Toil."
- **Google SRE Workbook** — "Canarying Releases" (automated verification gates between rollout stages = the industrial form of clause 2).
- Progressive delivery in practice: Argo Rollouts; Netflix Kayenta / Spinnaker automated canary analysis.

Optional, for the frontier (§3):
- Hutchins, *Cognition in the Wild* (distributed cognition / external memory).
- Simon on bounded rationality.

---

## 7. Open questions to think deeper on

- How do you keep the operator's judgment *sharp* despite Bainbridge's de-skilling, when the run only escalates the hardest cases? Is the journal enough, or is periodic hands-on rotation needed?
- What does a verification criterion look like for a *non-deterministic* agent step (where re-running doesn't reproduce)? Where do statistical / multi-sample gates replace binary pass/fail?
- Is the journal really "external working memory"? If so, what does the distributed-cognition literature say about how to structure it (what to externalize vs keep in-context)?
- Can stop conditions be *learned* from past runs rather than enumerated by hand — and is that safe, or does it reintroduce the stochastic-actor problem at the safety layer?
- Where is the honest ROI line on verification effort for a homelab (low stakes) vs. the SRE practices designed for high-stakes production?
