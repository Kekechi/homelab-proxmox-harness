---
name: polish
description: Iterative review-fix loop for design records, plan docs, or generated code. Runs the appropriate reviewer subagent, fixes blocking issues in a fixer subagent, and loops until APPROVE. All fix+re-review cycles stay in subagents — main context only sees the final verdict.
disable-model-invocation: false
---

# Skill: Polish (Iterative Review-Fix Loop)

Run the appropriate reviewer subagent on an artifact, fix any blocking issues in a fixer subagent, and repeat until APPROVE. All work stays in subagents — the main session only sees the final verdict.

## Artifact Types

| Type | What to review | Reviewer |
|---|---|---|
| `code` | Modified `.tf` and Ansible files in the working tree | tf-reviewer agent |
| `plan` | `.claude/session/plan-<name>.md` | general-purpose agent (plan checklist) |
| `design` | `docs/design/<name>.md` or `.claude/session/design-<name>.md` | general-purpose agent (design checklist) |

## Instructions

### Step 1: Determine artifact type and scope

- If called with an explicit argument (e.g. `polish code`, `polish plan log-server`, `polish design dns`), use that.
- If no argument, infer from context: if there are recently modified `.tf` or Ansible files, default to `code`; otherwise ask.

### Step 2: Determine files to review

- **`code`:** Run `git diff --name-only HEAD` to list all `.tf` files and Ansible files (`roles/`, `playbooks/`) modified in the working tree. If no HEAD diff (fresh branch), use `git status --short` instead.
- **`plan`:** Use the path passed in the argument (e.g. `polish plan log-server` → `.claude/session/plan-log-server.md`), or if no path, the most recently written `.claude/session/plan-*.md`.
- **`design`:** Use the path passed in the argument (e.g. `polish design dns` → `docs/design/dns-design.md`), or if no path, the most recently written file matching `docs/design/*.md` or `.claude/session/design-*.md`.

### Step 3: Run the review-fix loop

**Repeat until verdict is APPROVE or WARN:**

1. Launch the appropriate reviewer subagent (see Reviewer Subagents below) with the full file list or document path and all relevant context.
2. If verdict is **BLOCK**:
   - Launch a general-purpose fixer subagent with:
     - The exact list of blocking issues from the review report
     - The file list or document path to fix
     - Instruction: fix all blocking issues and nothing else — no refactoring, no added features
   - After the fixer subagent completes, return to step 1 with the same file list.
3. If verdict is **APPROVE** or **WARN**: exit the loop.

**Do not fix issues in the main session.** All review and fix work happens in subagents. The main session only receives the final verdict.

### Step 4: Report to the user

- **APPROVE** — report clean. State the artifact and how many review iterations it took if more than one.
- **WARN** — present all warnings and ask the user whether to proceed.

---

## Reviewer Subagents

### `code` — tf-reviewer agent

Launch the `tf-reviewer` agent (defined in `.claude/agents/tf-reviewer.md`) with the list of modified files.

The tf-reviewer checks Terraform security, bpg/proxmox provider correctness, sandbox scope, and Ansible task idempotency.

### `plan` — general-purpose subagent

Launch a general-purpose subagent to review the plan document. Instruct it to check for:

- Missing module arguments that cause silent failures (`headers:` on `uri`, `status_code:` lists, `changed_when:` on `shell` tasks)
- Idempotency gaps (unguarded commands, missing `stat` checks before init tasks, `when:` conditions that skip cleanup)
- Service ordering dependencies (handler flush timing, `wait_for` placement before API calls)
- Template correctness (YAML quoting, config key names matching the target software version)
- String format mismatches between tool input and output syntax (e.g. `setcap` uses `+ep`, `getcap` outputs `=ep`)
- JSON body type fidelity: when `uri` uses `body_format: json`, Jinja2-templated values must land as the correct JSON type — quoted YAML scalars pass through `to_text()`, so `| int` alone does not guarantee a JSON integer unless `jinja2_native = true` is set
- Cross-layer consistency: every variable the generator is expected to emit must be declared in `variables.tf`; every Ansible variable referenced in templates must be sourced from inventory or defaults

Return format: list of blocking issues (verdict: BLOCK), warnings (verdict: WARN), or clean (verdict: APPROVE).

### `design` — general-purpose subagent

Launch a general-purpose subagent to review the design record. Instruct it to check for:

- Decisions recorded with Evidence basis: Inferred that have no verification path and would block planning if wrong
- Missing decisions needed before planning can start (sizing, OS, naming conventions, secret management)
- Component dependencies not reflected in the design (e.g. a service that requires another service not mentioned)
- Scope creep: items that belong in planning or deployment, not in the design record
- Design record completeness: must contain Goal, Design Decisions table, Component Summary, Open Items, and a "Ready for planning" statement

Return format: list of blocking issues (verdict: BLOCK), warnings (verdict: WARN), or clean (verdict: APPROVE).

---

## Usage Examples

```
/polish                         # infer from working tree (defaults to code)
/polish code                    # review all modified .tf and Ansible files
/polish plan log-server         # review .claude/session/plan-log-server.md
/polish design dns              # review docs/design/dns-design.md
```

## How Deploy Skills Use This Skill

The deploy skills delegate their review phases here rather than implementing the loop inline:

| Caller | Stage | Call |
|---|---|---|
| `ansible-deploy` Step 1b | Plan review before code generation | `polish plan <plan-name>` |
| `tf-deploy` Step 3 | Code review before terraform plan | `polish code` |
| `ansible-deploy` Step 3 | Code review before ansible-run | `polish code` |

When called from a deploy skill, proceed directly — do not ask for the artifact type.
