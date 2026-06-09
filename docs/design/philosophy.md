# Engineering Philosophy of This Project

> A reflective record of *how* this homelab was built — the commitments that drove the
> architecture, traced to the concrete decisions that prove them. Reconstructed from the
> git history (Mar 29 onward), the design records in this directory, and the surviving
> session transcripts (June). It is intent-level by design: it names principles and the
> decisions they produced, not network topology.

## How to read this

Most "engineering philosophy" writing is a list of virtues nobody disagrees with. This is
the opposite: every principle below is anchored to a **dated decision where the principle
beat the easier alternative** — and to the tensions where it cost something or only half
held. If a claim has no decision behind it, it isn't in here.

The surface of the project is a dozen-odd operational principles. Underneath them are **four
root commitments** that generate the rest. The useful insight isn't the principles — it's
that they aren't independent. They fall out of four prior beliefs about authority, truth,
cost, and humility.

---

## The deep grammar: four root commitments

| Root commitment | One-line form | Principles it generates |
|---|---|---|
| **I. Authority** | Authority must be minimal, explicit, and structural. | Structural boundaries · pervasive least privilege · defend the actual threat |
| **II. Truth** | Truth comes from the running system, not from memory. | Verify-don't-assume · label what you don't know · preserve negative knowledge |
| **III. Cost** | Pay now so you don't pay forever. | Upfront investment · staged gates · one pattern everywhere · the process improves itself |
| **IV. Humility** | Prefer the boring, reversible path. | Accepted default over clever workaround · build with exits · separate permanent from disposable |

The single sentence that the project's own June retrospective converged on sits across all
four: **move authority out of memory and intention and into structure, so that being correct
is the path of least resistance and being wrong fails loudly and early.** That is commitment I
and II fused — and III and IV are how you afford to live that way without grinding to a halt.

---

## I. Authority must be minimal, explicit, and structural

### A1 — Boundaries are mechanisms, not policies

A boundary you *could* cross but promise not to is not a boundary. Wherever a rule said
"never," the project worked to back it with a mechanism that makes violation *fail*, not one
that asks for restraint.

The defining artifact is a 24-hour reversal at the very start. The initial harness
(`236dab4`, Mar 29) shipped a `sandbox-guard` subagent — an LLM "soft advisory" that would
*reason about* whether an action was safe. **One day later (`3481429`, Mar 30) it was deleted**
and replaced by deterministic `PreToolUse` hooks, with the commit stating plainly that the
soft advisory "is replaced by the above hooks." The hooks don't reason; they pattern-match and
`exit 2`. And they were made self-protecting — the agent is blocked from editing the very
hooks that constrain it. An enforcement that could be *persuaded* was swapped for one that
*cannot*. That single decision is the whole philosophy in miniature.

The same shape recurs everywhere:
- The production credential is **physically absent** from the dev container — production
  applies fail at authentication, not at a policy check.
- The dev container sits on a no-egress network; **all** traffic must cross a forward proxy
  whose allowlist is *baked into the image*, not mounted — so even with workspace write
  access, the running policy can't be altered without an operator rebuild.
- Reaching production fails at **two independent layers** (proxy allowlist *and* credential
  scope), so no single bypass is sufficient.

### A2 — Least privilege at every layer, by default *(under-named until now)*

This is distinct from A1. A1 says boundaries are real; A2 says the *default grant at every
layer is the minimum*, not just at the one obvious choke point. The pattern shows up at a
striking number of layers that didn't have to be locked down:

- The automation role **omits** the privileges for the things it must never do (creating
  users, moving resource pools), so those are *impossibilities* returning an authorization
  error — not forbidden actions.
- Containers run with **all Linux capabilities dropped** and no-new-privileges, so a rogue
  process can't manipulate networking even if it wanted to (`2edda65`, Mar 31).
- The internal CA **restricts its own issuance** to an explicit name policy patched into its
  config (`211abe0`) — the CA can't sign arbitrary names even though it technically could.
- The DNS frontend uses an **explicit client allow-list**, not the convenient "all private
  networks" default, on the stated reasoning that future hosts "must be consciously added."
- The SIEM service account gets a **dedicated role with a single capability**, not a reused
  admin login.

No layer was left at its permissive default just because the layer above it already
constrained things. Least privilege is treated as the *posture*, not a feature of the IAM
layer.

### A3 — Defend the actual threat, not the generic one

Before hardening, the project re-derives *what the boundary is actually defending against*.
The clearest decision: the pre-commit credential scanner was **swapped for content-lint hooks**
(`c3621ed`, Apr 15) on the explicit reasoning that for a public repo "the actual risk is
information leakage, not credential leakage." That reframing produced its own structural
boundary — internal addresses were untracked and replaced with placeholders before the repo
went public (`73cbbf6`), and a content check now guards every commit. The line between *what we
did* and *what we reveal* became a real, enforced boundary, distinct from the access boundary.

---

## II. Truth comes from the running system, not from memory

### B1 — Verify against the source; never trust training knowledge

The project repeatedly treats a model's confident assertion as a *hypothesis to check*, not a
fact. The canonical case: a plan specified an integration config key as one string and the
plan's *own notes asserted it was correct* "per the naming convention." The plan-review pass
returned **BLOCKING** — the real key was different, cited directly to the upstream component
README rather than to memory (June). The same instinct recurs structurally: design records
carry "verify on first deploy" tables; config syntax is checked with a parse/validate step at
build time; a sub-task was once dispatched *solely to fetch* the official reference and return
"exact field names and types from the docs, not inferred."

### B2 — Label what you don't know *(under-named until now)*

Beyond verifying before acting, the artifacts themselves are **honest about confidence**. The
DNS design records ship explicit "Unvalidated Assumptions — verify on first deploy" tables that
name the exact command that would confirm each one. `known-issues.md` lists unsolved problems
plainly rather than burying them. The project's own retrospective concedes that some of the
"enterprise" framing is "partly aspirational… slightly ahead of operational reality." Calibrated
confidence — distinguishing *known* from *hypothesised* in the written record — is a practice,
not just an attitude. It is what makes B3 possible.

### B3 — Preserve negative knowledge: dead ends are first-class artifacts *(under-named until now)*

When a path is abandoned, the project **documents why, durably**, instead of silently deleting
it. The DNS query-log pipeline was designed, deployed, *invalidated by live testing*, and then
**re-documented with the dead end preserved**: this very directory's `dns-log-pipeline.md` opens
with a "What Was Invalidated" section explaining that the original transport emitted the wrong
signal type and self-terminated on the real input — and, critically, records that the obvious
"fix" (switching the upstream to a different wire format) was *considered and rejected* because
its only benefit had no value to a SIEM. A whole separate design record exists for a single
generator bug (`minio-endpoint-tls-generator-bug.md`). Failure is captured as evidence, not
erased. This is why the early record survived the loss of the raw transcripts: the *reasoning*
was written into durable artifacts, not left in the conversation.

---

## III. Pay now so you don't pay forever

This is the "think like an enterprise" instinct stated precisely: **accept upfront
implementation cost to drive the marginal cost of every future change toward zero.**

### C1 — Front-load investment to crush marginal cost

The decisive proof is dated. **On Mar 30, when only one service existed**, the project committed
a config-generation system (a generator now ~1,100 lines) plus a prohibition on hand-editing the
files it produces. One source-of-truth YAML now emits Terraform variables, the Ansible inventory,
the proxy allowlist, and the secret-boundary-respecting environment skeleton *simultaneously* —
adding a service is one YAML entry, and downstream artifacts auto-derive. One expensive generator,
built before it was strictly needed, bought down the cost of every deployment after it. The
multi-agent plan→generate→review pipeline was likewise built on day one, before there was much to
deploy.

### C2 — Stage the work behind gates

Work moves through explicit, gated stages — `/design` → `/infra-plan` → `/generate` → `/review`
— with roles deliberately isolated (the code generator's own brief says "you do NOT plan… you do
NOT review"). Reasoning budget is spent where it pays: the planner runs on the strongest model,
the generator and reviewer on a cheaper one. The stated logic is "bugs caught in plan text cost
nothing" — so review was *shifted left* into plan-review-before-generate and
design-review-before-generate gates. The bet, written into the deploy skills, is explicit: the
cost of a gate is less than the cost of a bad apply.

### C3 — One pattern, applied everywhere *(under-named until now)*

When a good pattern exists, the project pays to apply it *uniformly* rather than taking a locally
cheaper one-off. Every service onboards TLS the same way ("same reason the others use the
generator"). The most telling case: faced with adding one service's TLS config, the choice was
between hardcoding two values (easy, local) and **extending the generator** to emit them
(harder, consistent) — and the harder, uniform path was chosen on purpose, to keep environment
specifics out of committed files and stay consistent with the existing services. Uniformity is
treated as worth a real upfront premium, because consistency is what keeps the *operational*
cost low.

### C4 — The process improves itself *(under-named until now)*

The build process is treated as architecture that *iterates on itself*. A `/retro` skill
institutionalizes turning each session into either a memory or a process change; lessons become
durable rules. The sharpest example is self-correcting: the project noticed that a prototype
which **skipped the design phase** burned three-plus review cycles because tool assumptions only
surfaced at runtime — and codified the lesson "a third review cycle means stop and go back to
`/design`, not another fix round." The system that builds the homelab has a feedback loop into
its own quality.

---

## IV. Prefer the boring, reversible path

The counterweight to III. Investing upfront is only safe if you invest in *standard, reversible*
things — otherwise front-loading just multiplies the cost of a wrong bet.

### D1 — Best accepted default over clever workaround

Novelty is treated as a cost, not a virtue. The authoritative resolver was colocated "per the
official migration guide" rather than via a bespoke split; a capability grant replaced a custom
reverse-proxy hack for binding a privileged port (`54b8f52`); config-file editing is treated as
the *native* interface for self-hosted tools, not an inferior substitute for an API. The vivid
"we rejected the clever path on purpose" moment is in B3: when a pipeline broke, the cleverer fix
was explicitly declined in favor of reusing an already-proven transport.

### D2 — Build with exits; preserve reversibility *(under-named until now)*

Decisions are made so they can be *un-made*. The self-hosted state backend was adopted **with a
documented migration path left in place** — the choice to own the dependency came with a
pre-built door out. Infrastructure phases are gated by flags so undeployed phases "cost nothing"
(`33f56c4`) and can be rolled out or rolled back independently. The `/design` phase decides "one
decision at a time," which keeps each commitment small and individually reversible. Optionality
is treated as something you *engineer in*, not something you hope you kept.

### D3 — Separate the permanent from the disposable *(under-named until now)*

A genuine architectural axis, not just tidiness: the **collection layer is built to outlive the
analysis layer**. The telemetry collector is "permanent infrastructure," gated *separately* from
the SIEM, with a backend-agnostic export config — explicitly so that sources never need
reconfiguration if the analysis tool's license lapses. Logs fan out to durable object storage
*and* to the live analysis sink. Every shipping and retention decision descends from this one
split between what must persist and what is swappable.

---

## Where the principles collide

These commitments are not free, and they don't always agree. The honest record shows the seams.

- **III outran the deployment order (the central live tension).** TLS-everywhere (root I) moving
  faster than the bootstrap sequence produced a chicken-and-egg: package installs need the
  internal CA trusted, but trusting the CA needs working package installs. It is currently held
  together by acknowledged-temporary mitigations and flagged for a multi-role refactor. The record
  names it as a root-cause-at-the-wrong-layer problem rather than papering over it — B2 and B3 in
  action even about the project's own unfinished work.
- **The one boundary that is human, not mechanism.** Dev-container changes are inert until an
  operator rebuilds — so the final gate there is a human reviewing the diff, not a mechanism. The
  threat model states the residual risk outright. This is the place A1 is aspirational rather than
  enforced.
- **C1/C2 can overshoot into C4's lesson.** The same instinct that front-loads investment is the
  one that paid the *review* cost three times over when the cheaper *design* cost once would have
  done. Knowing *which* stage deserves the upfront spend is itself a discipline the project had to
  learn the hard way.
- **The headline capability is the least finished.** The conversational-AI layer over the SIEM —
  the project's marquee feature — currently ends at a manual step, because the integration token
  has no automatable issuance path (verified: no API exists). The pipeline that feeds it is healthy;
  the consumption layer is stubbed. The free analysis tier also caps detection at query-driven
  rather than correlation-driven — an accepted ceiling, named plainly.
- **One place the single-source-of-truth rule wasn't applied to the harness itself.** Convention
  text is *copied* into two agent briefs with a comment pleading "update both" — the one spot where
  the generator discipline (C1) gave way to manual sync.

A pattern worth noting in the tensions themselves: nearly every one is *documented by the project*,
not discovered against it. The seams are visible because B2/B3 made them visible. That is arguably
the most load-bearing trait of all — the philosophy is self-aware enough to record where it
doesn't yet hold.

---

## What it adds up to

Four root commitments — **minimal explicit authority, truth from the system, pay-now-not-later,
and a preference for the boring and reversible** — generate roughly a dozen operational
principles, and those principles are visible as *dated decisions that beat an easier
alternative*, not as slogans. The throughline the project keeps returning to is the conversion of
intention into structure: a guard agent into a deterministic hook, a hand-edited file into a
generated one, a manual cert into an auto-renewing one, a forgotten dead end into a written
design record.

The most honest thing to say about it: the *isolation, generation, and verification* machinery is
genuinely built and load-bearing; the *enterprise framing* around it occasionally runs ahead of
operational reality; and the project knows the difference and writes it down. A philosophy that
records its own gap between aspiration and reality is one that can actually close it.
