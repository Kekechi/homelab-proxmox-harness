# Deployment Verification Layer — Session Brief

**Status:** planning complete, ready for execution
**Objective:** Build a tiered verification layer that proves each deployed service is *live*, *completely deployed*, and *working as intended* — a cheap machine gate wired into the rebuild loop, plus an on-demand agent sanity sweep that surfaces semantic smells (e.g. the confusingly-named PKI provisioner) — while making **no** trust-model changes.

*(Work plan for an autonomous agent, not a design record. Cites `file:line`; carries no environment specifics — resolve hosts/domain/IPs from `config/<env>.yml` at runtime. Per-service ground-truth detail lives in the uncommitted `.claude/session/recon-*.md` files produced during planning.)*

---

## 1. Operating model

Autonomous; the main thread orchestrates and subagents execute; **verification is live** against the deployed sandbox (confirmed reachable at planning time: 7/8 hosts pong, splunk host off by design). Capture real system behavior, not reasoning. The destroy→rebuild loop (`scripts/loop/*`, `make loop-*`) is the harness for regression-gate work.

### Design spine — two findings that shape everything

1. **Ansible has no Terraform-style state diff.** Verified live during planning: `ansible-playbook --check` *fails outright* on the complex roles (nexus, dns) because until-poll / shell / command tasks cannot be simulated, and false-drifts elsewhere (minio). **Check mode is therefore NOT a completeness mechanism here** and must not be reintroduced as a hard gate.
2. **Verify behavior, not files.** The truthful check queries the *running system* (`step ca provisioner list`, served-cert inspection, API status, `dig`, `mc admin info`) — not the config file that is *supposed* to drive it. The daemon is truth; the file is intent; they diverge.

### Tiered assertion model

| Tier | What | Cost / cadence | Modality |
|---|---|---|---|
| **Tier 1 — machine gate** | liveness + a few *critical behavioral* assertions, queried live | cheap, every loop | hard `exit 0/1` |
| **Tier 2 — agent sanity sweep** | collector scripts dump *raw* behavioral state; a skill drives the agent to judge "working as intended? any smell?" → findings | expensive, on-demand | agent judgment |

Tier 2 is the `acme`-class detector: catching "this provisioner name is confusing and over-scoped" is a *judgment*, not a hard assert you could write before knowing. A **known plant** validates it: `acme` is in the live CA now, so "the sweep run today surfaces it" is a machine-checkable criterion for an otherwise-fuzzy layer.

### Regression matrix — both states of every legitimate toggle

A single config (the current sandbox override set) tests only one path. The regression set covers **both legitimate states of each config toggle**, tested **one-at-a-time from a baseline** — not the 2ⁿ cross-product (exponential rebuilds, little extra signal). Concretely: baseline + `minio.tls:true` + `splunk.enabled:true` + apt `fail` mode ≈ 4 loop passes, each gated by `verify-all`. Use `--keep-minio` to avoid rebuilding MinIO every iteration where it is not the variable under test.

**`minio.tls:true` is not a free toggle.** The shared MinIO LXC *is* the Terraform state backend, and the endpoint scheme is decoupled from `minio.tls` (`backend.tf:13,40`; generator wires `minio.tls` only to the otelcol sink, `generate-configs.py:743`). So the tls:true pass must first wire to `minio.tls`: (1) the `MINIO_ENDPOINT` scheme in `.envrc`; (2) CA trust for Terraform's S3 client (`AWS_CA_BUNDLE` → `/workspace/.pki/root_ca.crt`); (3) an IP/FQDN SAN on the MinIO cert matching the endpoint. These must land **before** the tls:true `init`, or the loop bricks its own state access. Squid already permits TLS MinIO (port 9000 ∈ `SSL_ports`, squid.conf:36-37) — no `.devcontainer` change. This is the production-representative case (prod state bucket over TLS).

---

## 2. Autonomy contract

### Authorization manifest  *(operator-signed; `/auto-run`'s authoritative scope)*

| Action class | Disposition |
|---|---|
| Read-only live queries (ssh, API GET, `dig`, cert/provisioner inspect, `mc admin info`) | **Authorized** — any sandbox host |
| `ansible-playbook --check` (read-only) | **Authorized** — any sandbox host |
| Real (mutating) ansible deploy | **Authorized** — sandbox only |
| Restart / stop a service on the live sandbox | **Confirm-at-runtime, bounded** — Authorized for non-critical services (nexus, minio, log-server); **Forbidden** for issuing-CA, root-CA, and the resolver chain (auth/recursor/dnsdist) |
| Expiry test (shorten cert duration → let lapse → stop renewer) | **Authorized only** on a nexus or minio cert; **Forbidden** on any CA or resolver cert |
| Destroy→rebuild loop, incl. full `--include-vms` teardown (destroys LXCs **and** VMs) | **Authorized — sandbox pool only.** The required whole test (cold start from nothing). Resolver fallback confirmed (§3) → `--include-vms` unblocked |
| Power on / create the splunk guest via sandbox `terraform apply` (for WS4b) | **Authorized** — sandbox plan-file only |
| Wire `minio.tls` to the TF state backend (`.envrc` `MINIO_ENDPOINT` scheme, `AWS_CA_BUNDLE`, MinIO cert SAN) | **Authorized** — sandbox; must precede any tls:true `init` |
| Edit `config/sandbox.yml` test toggles (`minio.tls`, `splunk.enabled`) for matrix passes | **Authorized** — sandbox; **must revert** test overrides before finishing |
| Add the shared `nexus_fallback` default (generator / group_vars) + the loop's bootstrap override | **Authorized** — phase-keyed run param, **not** per-env config |
| Edit roles / scripts / Makefile / new verify scripts / new skill | **Authorized** |
| Re-baseline golden fixtures (`test-golden.py --update`) | **Authorized — must review `git diff` of `scripts/golden/`**, never blind-update |
| `terraform apply` | **Authorized** — sandbox plan-file only (via loop); production **Forbidden** |
| `git commit` | **Authorized** — no push |
| `git push` | **Forbidden** (deny rule active) |
| PKI provisioner redesign / any trust-model change (names, scopes, signing) | **Forbidden** — surface as a Tier-2 finding only |
| Modify `.devcontainer/` | **Forbidden** (autonomous) |

**Enforcement tiers** — where guardrails actually matter:

| Tier | Holds because | Guardrail |
|---|---|---|
| Environment-enforced | prod token absent; out-of-pool + non-sandbox hosts unreachable through Squid | none needed — free safety |
| Discipline-required | environment allows; only policy forbids | `git push` deny rule (✓); **stop conditions** for CA/resolver restart, golden blind-update, trust-model change |
| Relaxed | the Authorized set above | none |

### Stop conditions  *(halt and return the specific decision)*

1. A second workaround at the same layer (the fix is at the wrong layer).
2. The same step fails twice with the same root cause.
3. A verification criterion fails with no root-cause hypothesis.
4. An action not **Authorized** on the manifest, or one marked **Confirm-at-runtime**.
5. New work that shifts the **objective** (new work *within* manifest + objective is absorbed and journaled).
6. Session-specific tripwires:
   - About to restart/stop the issuing-CA, root-CA, or resolver chain → **STOP** (cuts the dev container's own DNS→CA path — self-brick).
   - An expiry/renewal test about to target a CA or resolver cert → **STOP**.
   - About to run loop teardown with `--include-vms` before the §3 resolver fallback is confirmed → **STOP** (self-brick).
   - `minio.tls:true` pass: Terraform `init`/state access fails against the TLS backend → **STOP** (the endpoint-scheme / `AWS_CA_BUNDLE` / cert-SAN wiring is wrong; don't thrash on a backend the loop itself depends on).
   - Golden test fails after a generator change with no understood cause → **STOP** (do not blind `--update`).
   - Tempted to reintroduce check mode as a hard completeness gate → **STOP** (verified unreliable).
   - Splunk re-enable: HEC token mismatch unresolved after one root-cause attempt → **STOP** (don't thrash).
   - A Tier-2 finding implies a trust-model change → record it, do **not** implement (that's a `/design` item).
   - WS5 about to set `nexus_fallback` default to `fail` without the `run.sh` `upstream` bootstrap override in the same change → **STOP** (would brick every later cold rebuild — the harness — at the PKI phase).
7. **No-progress / time ceiling:** a single workstream consumes more than ~2 full loop rebuilds (or its allotted iterations) without meeting its verification criterion → **STOP** and report, rather than grinding. Journal the no-progress count per workstream.

### Journal protocol

Run journal: `.claude/session/verification-layer-journal.md` (uncommitted) — objective line, decisions + why, the open-decisions ledger (each item closed-with-resolution or carried-forward), and a step ledger (`step → outcome → artifact/commit`). Tier-2 output: `.claude/session/verification-findings.md`. These are the operator's async audit surface.

---

## 3. Prerequisites (operator, before the session)

- **Sandbox deployed & reachable** — verified live at planning (7/8 hosts; splunk off by design). If torn down since, redeploy first: the live tiers need a running system.
- **Public-DNS resolver fallback present** before any `--include-vms` teardown — **confirmed** (operator, same as the prior session). This unblocks the full `--include-vms` cold-start test.
- **Aware of the `config/sandbox.yml` test overrides** (`minio.tls:false`, `splunk.enabled:false`, `dns_server`): intentionally present; the matrix passes flip them temporarily; all must be reverted for production.
- **apt-fallback design record — DONE** (`docs/design/apt-fallback-policy.md`): the switch is **phase-keyed, not env-keyed** — `nexus_fallback: upstream|fail`, default `fail`, bootstrap tooling overrides to `upstream`; scope = the 3 branching sites; sandbox tests **both** states. The autonomous run **implements** it (WS5); it does not re-decide the policy.
- `Bash(git push:*)` deny rule active (done in a prior session).
- **Sign the authorization manifest** above.

---

## 4. Workstreams (dependency order)

Each entry: approach / fix layer / **authorized actions (⊆ manifest)** / **verification criterion**.

### WS1 — Tier-1 machine verify layer *(the spine; build live)*
- **Approach:** per-service verify producing `exit 0/1`: liveness + a few critical **behavioral** assertions queried from the live box (behavioral-over-file). `make verify-<svc>` + `verify-all`, mirroring the `ansible-<svc>` Makefile house style; reuse existing in-role `verify.yml` logic where present (step-ca, nexus, pdns, dnsdist, dns-collector, splunk).
- **Fix layer:** new scripts + Makefile targets — **not** baked into the roles' deploy path (roles stay fresh-deploy-only).
- **Authorized:** read-only live queries; write scripts/Makefile; commit.
- **Verification criterion:** `make verify-all` is green against the live sandbox; then stop one unit → its `verify-<svc>` returns non-zero (proves it *detects*, not just passes), and restore.

### WS2 — Wire Tier-1 into the rebuild loop as a regression gate
- **Approach:** insert a hard-gating `per-service-verify` phase after `deploy` in `scripts/loop/run.sh` (current `scripts/loop/verify.sh` is evidence-only, always exit 0 — note this is a behavior change).
- **Authorized:** edit loop scripts/Makefile; run the loop (sandbox pool only); commit.
- **Verification criterion:** a full loop rebuild runs `verify-all` as a gate and passes; injecting a skipped role makes the loop stop at the gate.

### WS3 — Tier-2 agent sanity sweep + collectors *(surfaces the findings)*
- **Approach:** per-service collector scripts dump raw behavioral state (live provisioner list, served-cert SANs, effective otelcol pipeline, resolver backends, bucket policies); a new **skill** drives the agent to read + judge "working as intended? any smell?" → `verification-findings.md`.
- **Authorized:** read-only live queries; write scripts + skill; commit. **Forbidden:** acting on any trust-model finding.
- **Verification criterion:** the sweep run against today's sandbox **surfaces the known `acme` provisioner naming + wildcard-scope** as a finding (known plant). Findings recorded, none acted on.

### WS4 — Regression matrix + untested-path verifications *(fold-ins; verify live)*
Each toggle's two legitimate states get a `verify-all`-gated loop pass (one-at-a-time from baseline; `--keep-minio` where MinIO isn't the variable). Per sub-item: approach + its own criterion.
- **(a) Renewal happy-path + real expiry.** Confirm `step ca renew` at ~2/3 lifetime; then age a cert past `notAfter` and confirm re-enroll recovers — **on a nexus or minio cert only** (never CA/resolver — brick risk). *Criterion:* renew succeeds at 2/3 life **and** a cert taken past `notAfter` is recovered to a valid served cert.
- **(b) Splunk re-enable on-path** *(kept; Splunk is deprecation-bound but the flag exists until removal).* Power up the splunk guest (sandbox `terraform apply`), flip `splunk.enabled:true`, run a loop pass. *Criterion:* the otelcol `splunk_hec` exporter fires **and** a test event lands in Splunk (HEC token matches). On unresolved token mismatch → stop condition.
- **(c) MinIO re-enroll + `minio.tls:true` matrix pass.** Convert the minio renewer to the oneshot+timer self-heal pattern (as nexus). First wire the state backend to `minio.tls` (endpoint scheme + `AWS_CA_BUNDLE` + cert SAN, per §1) so the loop's own `init` survives tls:true. *Criterion:* a full tls:true loop pass goes green (incl. Terraform state over HTTPS) **and** a corrupted minio cert self-heals via re-enroll.
- **Authorized:** mutating sandbox deploy; `terraform apply` (splunk guest, sandbox plan-file); state-backend TLS wiring; bounded service restart/expiry on nexus/minio only; edit sandbox test toggles (revert after); commit.

### WS5 — Implement the apt-fallback policy *(per its `/design` record)*
- **Approach:** implement `docs/design/apt-fallback-policy.md`. Per the record: add `nexus_fallback` as a **run parameter** (shared default `fail` via generator / group_vars — **not** per-env config); add a `fail` branch in `ansible/roles/common/tasks/main.yml:62-159` and make the block/rescue in `otelcol/tasks/install.yml:14-26` + `dns_collector/tasks/install.yml:47-62` re-raise a clear message in `fail` mode; the loop's `run.sh` passes `-e nexus_fallback=upstream` on cold rebuild. The *policy* is the record's, not this run's.
- **Harness-safety (critical):** the new default is `fail`, but the loop's cold rebuild *is* this session's harness and depends on `upstream` (Nexus doesn't exist at the PKI phase). The `run.sh` `-e nexus_fallback=upstream` override and the `fail` default **must land in the same change**, immediately re-verified by one cold rebuild. Never leave `default=fail` without the override in place, or every subsequent rebuild bricks at the PKI phase. Do WS5 **late** (after the rebuild-dependent workstreams) for this reason.
- **Authorized:** edit generator/roles/example config; re-baseline golden (review diff); commit. **Do not** re-decide the policy — if the record is ambiguous, that's a stop condition (objective shift).
- **Verification criterion:** `scripts/test-golden.py` passes after any **reviewed** re-baseline; **sandbox exercises both states** — a cold rebuild (`upstream`) stays green, and a day-2 pass with `nexus_fallback=fail` stays green while Nexus is up **and aborts with the clear message** when Nexus is forced unreachable.

### WS6 — Progressive disclosure
- **Approach:** author `ansible/CLAUDE.md` and `terraform/CLAUDE.md` navigation guides (routing tables, conventions, "how to add X"; intent-level, public-repo clean). Physically split `scripts/generate-configs.py` (~1118 lines) → `scripts/genconfig/` per the decided per-output-artifact boundary in `scripts/CLAUDE.md:58-73`.
- **Authorized:** write docs; refactor generator; run golden gate; commit.
- **Verification criterion:** *(two parts — one machine, one judgment, named honestly per the skill).* **Machine:** the generator split makes `scripts/test-golden.py` pass **byte-identical without `--update`**, and the new `CLAUDE.md` files pass the public-repo leak scan (no domain/IP/VLAN/hostname/firewall name). **Judgment (no machine check exists for a navigation doc):** each guide answers a fixed checklist — how to add a host / add a role / the apt-via-Nexus convention / the step-ca cert-issuance pattern / env-var secret lookups / the syslog-forwarding contract — verified by review, not a gate.

### WS7 — Cleanups
- **Approach:** correct the disproven "token cannot clone (IAM)" rationale in `scripts/loop/teardown.sh:45-50` (+ `scripts/CLAUDE.md`) to the real storage/node-locality cause; consider flipping the `--include-vms` default now that locality is fixed. Dedup the syslog port (D5, noted in `scripts/CLAUDE.md`).
- **Authorized:** edit scripts/docs; run a full teardown+rebuild loop if flipping the default; commit.
- **Verification criterion:** comments corrected; if `--include-vms` is flipped, a full teardown+rebuild loop passes (else leave the default and fix comments only).

---

## 5. Sequencing rationale

- **WS1 first** — the spine; WS2/WS3/WS4 all build on its live-query plumbing.
- **WS2** wires WS1 into the loop; **WS3** reuses WS1's collectors and is the operator's payoff (it surfaces `acme`).
- **WS4** runs after WS1 (uses the verify targets to confirm recovery); otherwise independent.
- **WS5 late, but before WS6's split.** Late because it changes the cold-rebuild harness's own package-fetch default (the `fail`/`upstream` harness-safety note) — do it once the rebuild-dependent workstreams (WS1–WS4) are done. Before WS6 because both touch the generator + golden: WS5 changes generator output and re-baselines once; WS6's split must then preserve *that* output byte-identically. Net order: WS1→WS2→WS3→WS4→WS5→WS6.
- **WS7** anytime; smallest, do last or interleave.

---

## 6. Open items

- **Expiry-test target** (WS4a): nexus vs minio — agent picks within the non-critical allowlist (default nexus).
- **Loop verify gating** (WS2): hard-gate recommended; if brittle on the first rebuild, fall back to evidence + a separate gate and journal the reason.
- **Tier-2 cadence:** on-demand via the skill for now; whether it also runs (sampled) in the loop is deferred until Tier 1 + the sweep exist.
- **Resolved during planning:** apt-fallback → `/design` complete (`apt-fallback-policy.md`), **phase-keyed not env-keyed**; Splunk WS4b → kept + guest power-on authorized; `minio.tls:true` Squid reachability → verified non-blocking (port 9000 ∈ `SSL_ports`); the tls:true state-backend coupling → folded into WS4c with explicit wiring + a stop condition.
