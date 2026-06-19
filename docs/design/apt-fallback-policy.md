# Design: Nexus-Unreachable Fallback Policy (apt + raw artifacts)

## Goal
Hosts install packages from Nexus (the artifact server). When Nexus is unreachable, a deployment must either **fall back to upstream** (correct during bootstrap, when Nexus legitimately doesn't exist yet) or **fail fast with a clear message** (correct in steady state, when a missing Nexus is a real fault and — in a firewalled production — upstream is unreachable anyway). Today this fallback is implicit and behaves identically regardless of context, which silently chases an unreachable mirror during a production day-2 outage. This design makes the behavior an explicit switch keyed to **deployment phase, not environment**, so sandbox faithfully exercises the production failure path.

## Key reframe
The fallback is **not** an error handler — it is the **required happy path** for every host that deploys *before* Nexus exists. Deploy order is `common` first on every host, then **PKI → Nexus → DNS → log-server** (`scripts/loop/run.sh:155-159`, `ansible/playbooks/site.yml`). So the PKI hosts and the Nexus host itself bootstrap their base packages from upstream (the probe even excludes the Nexus host, `common/tasks/main.yml:74`); hosts after Nexus use Nexus. The mechanism that routes this per-host is the **probe** in `common` ("is Nexus up yet?"). The switch only decides what to do **when the probe finds Nexus down**: in bootstrap that's normal (→ upstream); in steady state that's a fault (→ fail). This mirrors the firewall lifecycle (`docs/guides/deployment-guide.md:121`: open during bootstrap, tightened to Nexus-only afterward).

## Design Decisions
| Decision | Choice | Rationale |
|---|---|---|
| **Keying** | By deployment **phase**, not environment | Behavior must not fork by env, or sandbox never exercises the prod `fail` path (zero coverage until production). Environments differ in config *data*, never behavioral *logic*. |
| **Switch form** | per-run parameter `nexus_fallback: upstream\|fail`, **default `fail`** | Fail-safe: chasing the internet is an explicit opt-in, not the default. |
| **Phase source** | bootstrap tooling sets `upstream` (the loop's `run.sh` on a cold rebuild; the prod initial-scaffolding runbook); day-2 paths use the `fail` default | Phase encoded in the tool, not in human memory. A cold deploy mistakenly run with the default fails *safe* with a clear message. |
| **Lives as** | a run parameter with one shared default — **not** in `config/sandbox.yml` / `config/production.yml` | Putting it in per-env config is exactly the env-keying being removed. |
| **Sandbox coverage** | sandbox runs **both** states (cold rebuild → `upstream`; deliberate day-2 pass → `fail`) | Faithful test of prod behavior; one of the parent session's matrix toggles. |
| **Scope** | the 3 sites with a usable upstream alternative: base-apt (`common`), otelcol DEB, dns-collector tarball | Only these *can* switch. Vendor apt repos (powerdns/dnsdist/smallstep) and Splunk have no usable upstream (apt-proxy with no fallback / login-gated raw) → Nexus-or-fail regardless of policy. |
| **Vendor repos** | left Nexus-or-fail; **no** pre-flight gate | Minimal. Only affects message clarity on a genuine day-2 outage; can add a clean pre-flight message later if wanted. |
| **`fail`-mode semantics** | retry the Nexus probe a few times, then abort with a clear message naming the cause ("Nexus unreachable — aborting; firewalled, no upstream fallback") | A transient blip shouldn't hard-fail; the message names the real cause, not a downstream apt error. |
| **Architecture** | keep the two existing shapes — `common`'s probe-decide and otelcol/dns-collector's block/rescue — both read `nexus_fallback` | They can't share one probe (the otelcol play has no `common`, so `common_nexus_reachable` isn't in scope there); no need to unify. |

## Component Summary
| Element | Role / file | Change |
|---|---|---|
| Per-host router | `common/tasks/main.yml:62-159` (probe → `common_nexus_reachable`) | add a `fail` branch when `nexus_fallback == 'fail'` and Nexus unreachable; keep upstream branch for `upstream` |
| Artifact rescue | `otelcol/tasks/install.yml:14-26`, `dns_collector/tasks/install.yml:47-62` | rescue checks `nexus_fallback`: `upstream` → current fallback; `fail` → re-raise with the clear message |
| Default + threading | generator (`scripts/generate-configs.py`) / shared group_vars | emit shared default `fail`; **not** per-env. Loop `run.sh` passes `-e nexus_fallback=upstream` on cold rebuild |
| Firewall (existing) | `deployment-guide.md:121` | open during bootstrap, tightened after Nexus — moves in lockstep with the switch |

## Open Items (deferred, not forgotten)
- **Scope B** — an optional single pre-flight "Nexus down" message covering the vendor apt repos in `fail` mode. Only improves a day-2-outage message; revisit if that ergonomics matters.
- **Default location** — `group_vars/all` vs a `common` role default — an implementation choice for the planner.
- **Prod cold-start bootstrap mechanics** — how the very first prod host installs base packages (covered by the firewall-open window per the operator); out of scope for this policy.

## Ready for planning
Design complete. **Implemented by WS5 of `docs/design/deployment-verification-layer.md`** (the autonomous verification session), or hand to `/infra-plan` as a standalone change. Verification: golden-test re-baseline if the generator emits a default; sandbox runs **both** `nexus_fallback` states green; `fail`-mode with Nexus down aborts with the clear message (not a downstream apt error).
