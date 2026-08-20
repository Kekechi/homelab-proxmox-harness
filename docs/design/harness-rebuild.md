# Design: Harness Rebuild (Component-Architecture Phase 5)

_Status: **agreed with operator 2026-08-20 — executing** on branch
`harness/rebuild` (stacked on `refactor/plugin-modules`). Public repo: intent level only._

---

## 1. Problem

The `.claude/` harness, `docs/guides/`, and parts of the Makefile still encode two dead
realities:

1. **The old wiring** — hand-written module blocks in `terraform/main.tf`, per-service
   `enable_x` variables, `ansible/playbooks/<x>-setup.yml`, hand-listed verify targets.
   The component refactor (phases 0–4, `docs/design/component-architecture.md`) replaced
   all of it, so the planner/generator agents and the deploy skills now instruct writing
   code to places that no longer accept it.
2. **The old dev environment** — the containerized, proxy-isolated agent environment is
   retired; the agent runs on a dedicated controller host. Rules, skills, and guides still
   describe the proxy allowlist as a live control and reference container-era paths.

Two claims are now **false and load-bearing**: deploy/troubleshoot docs state production
applies are "blocked by the terraform-guard hook" — the operator removed all hooks
(commit `daf074f`). The real enforcement is IAM: the production token is not present on
the controller host. Docs must say what is actually enforced and by what.

A full staleness audit (31 files: 18 skills, 3 agents, 10 guides, plus 6 rules) grounds
this record; verdicts summarized in §5.

## 2. Decisions (agreed 2026-08-20)

1. **The `/auto-plan` → `/auto-run` shape is deleted, folded into `/design` + a thin
   runner.** The design record itself carries the safety boundary; operator approval of
   the record is the go signal. A new thin `/free-run` skill keeps the habits worth
   keeping — journaling failures as lessons, per-slice commits, idempotency re-runs,
   `verify-all` as the gate — without boundary-doc/workstream/orchestrator ceremony.
2. **The PGE pipeline surface is retired.** `/infra-plan`, `/generate`, `/polish`,
   `/tf-deploy`, `/ansible-deploy`, `/ansible-run` and the `iac-planner`/`iac-generator`
   agents are deleted. Sandbox work executes in the main thread against an agreed design
   record. `/review` survives as a single-pass optional gate (its `tf-reviewer` agent
   rewritten component-aware); `/handoff` survives unchanged for production.
3. **Retired scaffolding is physically removed on this branch**: the Makefile's
   container-image `build:` and `verify-isolation` targets, and the unwired
   `scripts/hooks/*.sh`. The retired dev-environment directory is deleted in a
   **standalone final commit prepared for operator review** (operator-directed,
   2026-08-20), which also drops the now-moot prohibitions referencing it.
4. **Agent-side hooks stay removed.** Reviewed the four deleted hook scripts with the
   operator (2026-08-20): the terraform guard duplicated IAM enforcement and blocked a
   now-legitimate sandbox destroy workflow; the validate-after-edit and protected-path
   hooks are moot under the stable generic core. The one guard with residual value —
   the staged-secrets commit check, whose threat model is the public repo rather than
   the sandbox — is worth reinstating as a **plain git pre-commit hook** (protecting
   human and agent commits alike), but that relocation is **deferred** by operator
   decision; until then the operator's pre-push review is the gate.

## 3. Target surface

### Rules (6 → 5)

| Rule | Action |
|---|---|
| `sandbox-isolation.md` | Rewrite. Keep the durable core: plan-file gate, production plan-only, pool scoping, no state surgery, no secrets in tree, no generated-file edits. Drop container/proxy language. Absorb one intent-level paragraph from `network-policy.md`: the boundary is IAM + network position of the controller host, not a proxy. |
| `iam-model.md` | Rewrite tables against the controller host (what credentials exist there and what they can reach). Token/role/privilege content is current and stays. |
| `config-management.md` | Full rewrite: schema is owned by component manifests (`required`/`optional`/`defaults`); `config/<env>.yml` + gitignored `config/<env>.local.yml` overlay; accurate generated-files list (tfvars, inventory, `ansible.cfg`, non-secret `.envrc`, `.env.mk`, assembled examples); secret-boundary table survives as is. |
| `ansible-workflow.md` | Keep conventions (FQCN, APT-over-tarball, pinned collections). Replace the proxy-SSH section with controller-host reality; inventory is generated from enabled components. |
| `terraform-style.md` | Minor: state that root `main.tf` is generic `for_each` — adding a service never adds a module block; fix the keep-in-sync comment (now only `tf-reviewer` + `proxmox-module` mirror it). |
| `network-policy.md` | Delete (content is the retired proxy; surviving intent moves into `sandbox-isolation.md`). |

### Agents (3 → 1)

`tf-reviewer` is rewritten: component-layout checks (manifest sanity, no generated-file
edits, capability contracts instead of name reaches), drop proxy-era checklist items.
`iac-planner` and `iac-generator` are deleted with their pipelines.

### Skills (18 → 11)

| Skill | Action |
|---|---|
| `design` | Keep; delete the proxy pre-flight phase; the design-record template gains a short **execution boundary** section (what the session may touch, what is out of bounds) — this is what absorbs `/auto-plan`'s job. Handoff pointer becomes `/free-run`. |
| `free-run` (new) | Thin runner for autonomous execution of an agreed design record: journal failures as lessons (session doc), commit per coherent slice, idempotency re-run, `verify-all` / `verify-<component>` gates, `/retro` at the end. No subagents, no hooks. |
| `review` | Keep; rewrite around the new `tf-reviewer`. |
| `day2-ops` | Rewrite: day-2 changes are `config/<env>.yml` + `component.yml` edits + `make configure`, never `main.tf` edits; drop proxy checks. |
| `sanity-sweep` | Minor: collectors are `components/<name>/collect.sh` (discovery-driven), include `components.local/`. |
| `tf-plan-apply` | Minor: correct the `make configure` output list. |
| `tf-troubleshoot` | Minor: remove hook claims (state commands are rule-constrained, not blocked) and proxy diagnostics. |
| `proxmox-module` | Minor: scope note — module authoring only; root wiring is generic. |
| `assess`, `retro`, `handoff` | Keep as is. |
| `auto-plan`, `auto-run`, `infra-plan`, `generate`, `polish`, `tf-deploy`, `ansible-deploy`, `ansible-run` | Delete. |

### Guides (10) and top-level docs

- **Rewrite**: `deployment-guide.md` (controller-host framing, `verify-all` as final gate),
  `minio-setup.md`, `splunk-setup.md` (component playbook paths, no container steps),
  `prod-verify-runbook.md` (discovery-driven `verify-%` with real component keys).
- **Mechanical fixes**: `cluster-setup.md`, `non-managed-host-setup.md`, `pki-setup.md`,
  `trust-root-ca.md` (paths, dead target names, container-era prerequisites).
- **Last**: `skills.md` index and the `CLAUDE.md` skills table / repo-structure section,
  rewritten against the settled surface. `docs/network-policy.md` and
  `docs/threat-model.md` get a staleness pass for proxy-era claims.

## 4. Execution plan (commit slices)

1. `docs(design)`: this record.
2. `chore(make)`: remove `build:` / `verify-isolation`; delete `scripts/hooks/`.
3. `docs(rules)`: harvest + rewrite the five surviving rules; delete `network-policy.md`.
4. `chore(agents)`: delete planner/generator; rewrite `tf-reviewer`.
5. `feat(skills)`: delete the eight retired skills; add `free-run`; rewrite/touch the rest.
   (Order within: rules → `tf-reviewer` → `review`/`design` → dependents, per the audit's
   cross-reference map.)
6. `docs(guides)`: guide rewrites + mechanical fixes.
7. `docs`: `skills.md` + `CLAUDE.md` (skills table, structure, prohibitions cleanup).
8. `chore!`: delete the retired dev-environment directory — **standalone, operator reviews
   before merge**.

Verification: `make help` targets resolve; every `/skill` named in `CLAUDE.md` exists on
disk and vice versa; `grep` sweep for retired terms (container/proxy/hook-guard/old
playbook paths) over `.claude/` and `docs/` comes back clean; `make lint` passes.

## 5. Audit summary (2026-08-20)

FRESH: `assess`, `retro`, `review` (wrapper), `handoff`, `auto-run` (content, shape
retired anyway), `dns-cache-invalidation.md`. STALE-MAJOR: `generate`, `tf-deploy`,
`ansible-run`, `day2-ops`, `iac-planner`, `iac-generator`, `deployment-guide.md`,
`minio-setup.md`, `splunk-setup.md`, `prod-verify-runbook.md`. Everything else
STALE-MINOR (mechanical path/name/claim fixes). Cross-cutting: hook-enforcement claims
false since `daf074f`; Makefile `build:`/`verify-isolation` point at retired scaffolding.
