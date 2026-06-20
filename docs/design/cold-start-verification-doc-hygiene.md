# Cold-Start Verification & Doc Hygiene — Session Brief

Status: planning complete, ready for execution
Objective: Verify the un-loop-tested June deployment work via a full cold rebuild,
confirm the autonomy harness itself behaves as intended, and close the doc drift
(stale guides + missing operator prod-verify runbook).

> Work plan for an autonomous agent (`/auto-run`), not a design record. Cite
> `file:line`. No environment specifics — resolve IPs / domain / hostnames / VLANs
> from `config/<env>.yml` at runtime. Sandbox only.

---

## 1. Operating model

Orchestrator-only main thread; delegate execution and recon to subagents; journal
every step. Six workstreams in two tracks:

- **Rebuild track (WS1→WS2→WS3→WS4)** — a hard dependency chain. The payoff
  (WS3 green cold rebuild) closes "untested via destroy-deploy" (#1) and most of
  "is the harness working" (#4). Higher variance — gated on the MinIO readiness flake.
- **Docs track (WS5, WS6)** — independent of the rebuild, guaranteed-completable.
  Runs regardless; banks value even if the rebuild track halts.

Why this shape: the verification-layer session halted at the MinIO flake, so the
entire 9-commit June range (Tier-1 verify layer, hard gate, Tier-2 sweep, MinIO TLS
stage-1, nexus_fallback policy, apt-lock fix `b61cdc7`, generator split) is committed
but **never verified through a full cold rebuild**. Per the cold-start rule, only a
full fresh rebuild proves cold-start behavior.

---

## 2. Autonomy contract

### Authorization manifest (action class → disposition)

| # | Action class | Disposition | Scope / enforcement |
|---|---|---|---|
| 1 | Full sandbox teardown `--include-vms` (LXCs + MinIO + root-ca VM; regenerates trust chain) | **Authorized** | Sandbox pool only (`teardown.sh` filters by `terraform.pool_id`). Objective explicitly requires it. Template-pool VMs never deleted (`teardown.sh:107`). |
| 2 | Recreate LXCs/VMs via PVE API + cloud-init | **Authorized** | Sandbox only. |
| 3 | `terraform apply` **with plan file** | **Authorized** | Sandbox only; plan-file required (CLAUDE.md). Production = env-enforced impossible (token absent). |
| 4 | Run Ansible playbooks against sandbox hosts | **Authorized** | Sandbox inventory only. |
| 5 | Edit loop/verify scripts (`recreate-minio.sh`, `run.sh`, `verify.sh`, `verify/*`) | **Authorized** | WS2/WS4. |
| 6 | Author/edit docs (guides, runbook, design records) | **Authorized** | WS5/WS6; intent-level, public-repo hygiene. |
| 7 | `git commit` (untracked skills, design docs, code/doc changes) | **Authorized** | Local only. Never stage `.envrc`, `config/*.yml`, `*.tfvars/tfstate/tfplan`, secrets. |
| 8 | Regenerate offline root CA (side-effect of #1) | **Authorized** | Sandbox throwaway trust; `.pki` re-trust handled (`run.sh:95-97`). |
| 9 | Write scoped MinIO key to `.envrc` (`bootstrap-minio.sh`) | **Authorized** | `.envrc` is gitignored — never commit it. |
| 10 | Deliberate fault injection to test the verify gate (WS4) | **Authorized** | Sandbox; must be reverted/rebuilt; one service at a time. |
| 11 | `git push` | **Forbidden** | Structural rail: `Bash(git push:*)` deny rule. Operator pushes. |
| 12 | Modify `.devcontainer/` | **Forbidden** | CLAUDE.md (except `allowed-cidrs.conf` via `make configure`). |
| 13 | `terraform state rm/mv/import`, `force-unlock` | **Forbidden** | sandbox-isolation rule; needs operator. |
| 14 | Create Proxmox users/roles/tokens; move pools | **Forbidden** | Env-enforced (Permissions.Modify / Pool.Allocate excluded from role). |
| 15 | Any production apply | **Forbidden** | Env-enforced (token absent). |

No **Confirm-at-runtime** entries: the objective ("full cold rebuild + harness verify
+ doc hygiene, sandbox") authorizes the whole consequential set up front. The run does
not stop to re-ask for the teardown, the apply, or the commits.

### Stop conditions (halt and return the *specific* decision)

1. A readiness/rebuild fix becomes a **second workaround at the same layer** — e.g. WS2
   degenerates into another blind timeout bump rather than probing the real signal.
2. The same step fails **twice with the same root cause**.
3. A verification criterion fails with **no root-cause hypothesis**.
4. Any action **not Authorized** in the manifest is required to proceed.
5. New work that **shifts the objective** (within manifest + objective + verifiable →
   absorb and journal; otherwise halt).
6. Session-specific:
   - **WS1:** a recreation genuinely never becomes ready within a ~20-min ceiling →
     halt. That is the "sshd never came up" case (operator has never seen it) — a real
     infra fault, not a detection problem, and needs the operator.
   - **WS3:** a cold rebuild fails the **same phase twice** → halt. Do **not** loop
     rebuilds hoping for green (the prior session's failure mode).
   - **Budget:** at most **3 full `--include-vms` rebuilds** total (they are expensive);
     on the 3rd failure → halt with the evidence.
   - **WS4 fault-injection** that cannot be cleanly reverted/rebuilt → halt.

### Journal protocol

Run journal: `.claude/session/next-autorun-journal.md`. Holds: the objective line;
decisions + why; an open-decisions ledger (each entry closed with its resolution or
carried forward); a step ledger (`step → outcome → artifact link`). **At session end,
reconcile git state in the journal** — the prior session's journal falsely claimed
"9 commits un-pushed" / "WS7 not committed" after both had landed; do not repeat that.

---

## 3. Prerequisites (operator, before the session)

1. ✅ **`Bash(git push:*)` deny rule already active** (`settings.json:11`) — manifest #11
   is a live structural rail, no action needed. Other rails already present:
   `terraform-guard` (#3/#15), `pre-commit-guard` (#7), `protected-path-guard` (#12).
2. Confirm sandbox is the active env (`ENV=sandbox`) and the production token is absent
   (it should be — this makes #15 free).
3. Nothing else: brick-risks (resolver fallback, nexus_fallback override pairing, `.pki`
   re-trust) were verified live during planning and need no operator action.

---

## 4. Workstreams (dependency order)

### WS1 — Characterize MinIO LXC first-boot readiness  *(instrument; live-debug)*
- **Approach:** the current wait is a blind 720s wall-clock deadline polling SSH-through-
  Squid, then `die` (`recreate-minio.sh:140-151`) — zero data on *what* is lagging.
  Across ≥3 recreations (target a slow one), capture a timeline: PVE create/start task
  done → sshd actually bound *inside the guest* (via `pct exec` / guest agent) → reachable
  via the Squid CONNECT path. Identify the gap and its cause: sshd boot lag vs. the proxy
  path vs. the PVE NIC firewall (`net0` carries `firewall=1`, `recreate-minio.sh:63`).
- **Fix layer:** none yet — this is measurement. Tests the operator hypothesis ("sshd
  always eventually comes up; we just can't detect readiness") with evidence.
- **Authorized actions:** ⊆ {1,2}.
- **Verification criterion:** a documented readiness timeline across ≥3 recreations that
  names the actual readiness signal and the cause of the lag.
- Expansion-prone? No.

### WS2 — Reliable readiness probe  *(refactor)*
- **Approach:** replace the 720s blind deadline with a layered probe on WS1's real signal,
  logging *which stage* it is waiting on (so a future failure is diagnosable, not a black
  box). If the cause is the NIC firewall or proxy path, fix that instead of waiting.
- **Fix layer:** the readiness check in `recreate-minio.sh` (and any equivalent host-wait
  in `run.sh`). Not a timeout bump (stop-condition #1).
- **Authorized actions:** ⊆ {2,5}.
- **Verification criterion:** **M consecutive** recreations (≥3) each return ready *and*
  the subsequent Ansible play connects first-try — zero false "ready", zero false timeout.
- Expansion-prone? No.

### WS3 — Full cold rebuild  *(verification — the payoff)*
- **Approach:** `make loop` end-to-end with `--include-vms` and `minio.tls:false`
  (D1/TLS bootstrap deferred to `/design`). This is the only *coherent* teardown for a
  state reset: fresh MinIO = empty state, so the root-ca VM must also be destroyed or
  `terraform apply` collides on its vmid (see §finding in planning file; `run.sh:162`,
  `teardown.sh:45-47`).
- **Fix layer:** whatever cold-start gaps surface — fix at the role/loop layer, never a
  per-run hack.
- **Authorized actions:** ⊆ {1,2,3,4,8,9}.
- **Verification criterion:** cold rebuild reaches the green Tier-1 gate — `make verify-all`
  exit 0 — and the idempotency re-run of the deploy phase reports `changed=0` where roles
  claim idempotency. This simultaneously verifies the apt-lock fix `b61cdc7`,
  nexus_fallback, the verify layer, MinIO TLS stage-1 wiring, and the generator split.
- Expansion-prone? Moderate — cold-start gaps can cascade; budget-capped at 3 rebuilds.

### WS4 — Harness self-verification + commit  *(#4)*
- **Approach, three parts:**
  1. **Gate works:** a negative test — inject one service fault, confirm the loop's
     Tier-1 hard gate fails **red** (not silently green), then rebuild clean. Confirm the
     Tier-2 `/sanity-sweep` runs and surfaces its known findings.
  2. **Flip teardown default to `--include-vms` (full)** [operator-directed]: full
     teardown becomes the default because it is the only *coherent* mode after a MinIO/
     state reset (empty state + surviving TF-managed VMs → apply collision; `run.sh:162`,
     `teardown.sh:45-47`). Invert the flag to an opt-out (e.g. `--keep-vms`/`--preserve-vms`)
     for partial iteration — and that opt-out **must imply `KEEP_MINIO`** to stay coherent.
     Add a **fail-fast guard** for the now-rare incoherent combo (preserve VMs *and*
     recreate MinIO) and document the constraint in `scripts/CLAUDE.md` / loop headers.
     Update any references (Makefile help, `scripts/CLAUDE.md`, design records) that
     describe the old preserve-by-default behavior.
  3. **Commit hygiene:** confirm `/auto-plan` + `/auto-run` skills (currently **untracked**)
     hold the claimed edits from `skill-improvement-working-2026-06-18.md`; then commit
     the skills and the 4 untracked design docs (`apt-fallback-policy`,
     `deployment-verification-layer`, `minio-tls-state-backend-bootstrapping`,
     `splunk-hackathon-project`) and the modified `CLAUDE.md`.
- **Fix layer:** loop driver + git tree.
- **Authorized actions:** ⊆ {5,7,10}.
- **Verification criterion:** gate demonstrably **fails on injected fault and passes
  clean**; coherence guard trips on the incoherent invocation in a dry test; `git status`
  shows no untracked harness/design-doc files and no staged secrets.
- Expansion-prone? **Yes (recursive)** — the run commits the very `/auto-run` skill it
  executes under. Expect this; do not expand into re-designing the skills (that's v2,
  deferred). Commit-as-is-if-correct only.

### WS5 — Guide drift audit + fix  *(#2; independent)*
- **Approach:** all 8 `docs/guides/*.md` are dated 2026-04-14/04-21 — every one predates
  the June overhaul. Audit each against current code/state (commands, flags, file paths,
  service behavior). Delegate as a fan-out (one reader per guide), fix the drift.
- **Fix layer:** docs only.
- **Authorized actions:** ⊆ {6,7}.
- **Verification criterion:** every command/claim in each guide re-verified against current
  code (cite the source); per-guide change summary; public-repo content check passes (no
  IPs / domain / VLAN IDs / internal hostnames / firewall product names).
- Expansion-prone? Low.

### WS6 — Operator prod-verify runbook  *(#3; independent)*
- **Approach:** new `docs/guides/` runbook for how a human operator verifies a **prod**
  env: `make verify-all`, the per-service `make verify-<svc>` targets (`Makefile:49-77`),
  and the Tier-2 `/sanity-sweep`. Anchor on the production 10-step deploy sequence
  (see memory `project_production_deploy_steps` — Step 7b TLS on the mgmt port, Step 7c
  create the logs index before HEC). This is the "dedicated session" that
  `feedback_verify_targets_deferred` deferred to.
- **Fix layer:** docs only.
- **Authorized actions:** ⊆ {6,7}.
- **Verification criterion:** runbook covers every `verify-*` target + Tier-2, cross-checked
  against the actual `Makefile` targets; intent-level only; renders a clean operator path
  from "deploy done" to "prod verified".
- Expansion-prone? Low.

---

## 5. Sequencing rationale

- WS1→WS2→WS3→WS4 is a hard chain: you cannot prove cold-start (WS3) without a reliable
  recreate (WS2), which needs the characterization (WS1); WS4 verifies the harness that
  WS3 exercised and commits it.
- WS5/WS6 are independent of the rebuild and **guaranteed-completable**. Run them so a
  halt in the rebuild track (the high-variance part) still banks the doc-hygiene value.
  Suggested order: WS1, then WS5+WS6 (bank guaranteed work), then WS2→WS3→WS4.
- The flake is the single linchpin; if WS1's stop-condition (never-ready) trips, the
  rebuild track halts but the docs track still completes.

## 6. Open items (deferred, with destination)

- **D1 — `minio.tls:true` cold-start (CA bootstrap paradox)** → `/design`
  (`docs/design/minio-tls-state-backend-bootstrapping.md`). WS3 runs `tls:false`.
- **D2 — PKI provisioner naming + over-broad JWK scope** (Tier-2 findings F1/F2) →
  `/design`; prod needs backward-compat migration. (memory `project_pki_provisioner_naming`)
- **D3 — config `hostname:` field redesign** → `/design`. (memory `project_config_hostname_confusion`)
- **E — feature backlog** (DNS stages 2/3, artifact-server phases, MGMT VLAN creation,
  otelcol Nexus DEB, Splunk deprecation / Wazuh eval, task-mgmt v2 skill) → left in their
  design records; MGMT VLAN is the gating prerequisite for most prod feature work.
- **Skill v2** (resumable-executor architecture) → `docs/notes/task-management-research-report.md`;
  not this session (WS4 commits the v1 skills as-is).
