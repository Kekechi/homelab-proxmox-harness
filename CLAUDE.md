# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

Homelab Proxmox Private Cloud managed with Terraform (`bpg/proxmox` v0.99.0+) and Ansible.
State backend: MinIO (self-hosted S3, LXC on Proxmox) with a GitLab HTTP migration path.
The agent runs on a dedicated controller host; agent-host connection facts live in the config's `agent:` section (the old devcontainer/Squid setup is retired).

**This repository is public.** Do not commit or write to docs anything that reveals specific network topology, firewall product names, internal IPs, domain names, or deployment-specific implementation details. Keep committed docs at intent level.

---

## Explicit Prohibitions

- **NEVER** modify files under `.devcontainer/` autonomously — the devcontainer is RETIRED (component refactor); the directory awaits an operator-reviewed deletion. **Operator-directed edits are permitted when the operator explicitly requests them** (i.e. "edit this file", not inferred intent).
- **NEVER** run `terraform apply` without a plan file (`terraform plan -out=<file>` first)
- **NEVER** apply Terraform for production — produce a plan file and hand it to the operator
- **NEVER** commit `.envrc`, `config/*.yml`, or any file containing tokens, passwords, or secret keys
- **NEVER** modify the agent host's network configuration or probe networks outside the sandbox
- **NEVER** edit generated files directly (`terraform/*.tfvars`, `ansible/inventory/hosts.yml`, `ansible/ansible.cfg`, `config/*.yml.example`) — regenerate via `make configure` / `make examples`

---

## Environment Model

| Environment | Config file | Claude may apply? | State bucket |
|---|---|---|---|
| **sandbox** | `config/sandbox.yml` | Yes — plan-file required | `tfstate-sandbox` |
| **production** | `config/production.yml` | No — plan only | `tfstate-production` |

Switch environments with `ENV=`: `make plan ENV=production`
Production credentials (`operator-production` token, production MinIO key) never exist on the agent host — applies would fail at auth. This is intentional.

---

## Repository Structure

The repo follows a **component architecture** (see
`docs/design/component-architecture.md`): one directory owns one service
vertically; the core (terraform/, scripts/genconfig/, Makefile) is generic and
discovers components. Cross-component dependencies are capability contracts
(consumes/provides in the manifest), never component names.

```
components/               PUBLIC components — one dir owns one service
  <name>/
    component.yml         Manifest: instances (kind vm|lxc|none, resources,
                          tf_key/group), config required/optional/defaults,
                          consumes/provides (capabilities), env, seam, bootstrap
    config.example.yml.in Config fragment (assembled into config/*.yml.example)
    playbook.yml          Ansible entrypoint (roles/ resolve adjacent)
    roles/                This component's roles
    verify.sh             Tier-1 behavioral verify (discovered by verify-all)
    collect.sh            Tier-2 raw state dump (discovered by collect-all)
components.local/         GITIGNORED private components — identical layout,
                          discovered through the same code path; name/tf_key
                          collision with public components is a hard error
config/
  sandbox.yml.example     ASSEMBLED example (make examples) — edit the fragments
  production.yml.example    or example-core/<env>.yml.in, never this file
  example-core/           Per-env skeletons for example assembly
  <env>.local.yml         GITIGNORED private overlay — deep-merges over <env>.yml
.devcontainer/            RETIRED (operator deletes); do not modify
terraform/
  main.tf                 TWO for_each module blocks (vm/lxc) over var.services
  variables.tf            Shared vars + one typed services map
  outputs.tf              service_ids / service_addresses maps
  backend.tf              S3 backend — bucket passed at terraform init time
  modules/                proxmox-vm, proxmox-lxc, proxmox-network primitives
ansible/
  ansible.cfg             GENERATED — agent-host facts from config agent: section
  inventory/hosts.yml     GENERATED — enabled components only
  roles/                  genuinely shared roles only (common, step_client)
  playbooks/site.yml      common baseline for all hosts
scripts/
  generate-configs.py     Thin shim → scripts/genconfig/ (discover → validate →
                          resolve capabilities → emit; re-converge reporting)
  genconfig/              discovery.py, capabilities.py, validation.py, emit/*
  verify/verify-all.sh    Discovery-driven Tier-1 gate (per-component verify.sh)
  collect/collect-all.sh  Discovery-driven Tier-2 dumps
  loop/                   destroy→rebuild verification loop (sandbox only)
docs/                     proxmox-iam.md, network-policy.md, threat-model.md, vision.md
  design/                 cross-cutting design records (component-architecture.md, etc.)
  guides/                 operational how-to (deployment-guide.md, pki-setup.md, etc.)
.claude/
  agents/                 tf-reviewer (single-pass code review)
  skills/
    design/               Design exploration — one decision at a time → design record
                          (the record, once agreed, is the go signal)
    free-run/             Execute an agreed design record autonomously — journal,
                          per-slice commits, verify gates; no orchestration ceremony
    review/               Review code for security, correctness, and component fit
                          (tf-reviewer, Sonnet) — APPROVE/WARN/BLOCK
    handoff/              Package production plan for operator handoff
    assess/               Structured project assessment with discussion
    sanity-sweep/         Tier-2 judgment sweep over live state (record-only)
    retro/                Session retrospective — prompting lessons and skill lifecycle
    day2-ops/             Day-2 operations: resize, snapshots, network, cloud-init
    proxmox-module/       bpg/proxmox primitive-module authoring patterns (reference)
    tf-plan-apply/        Terraform init/plan/apply workflow (reference)
    tf-troubleshoot/      Diagnostic runbooks for failed Terraform operations (reference)
  rules/                  sandbox-isolation, terraform-style, iam-model,
                          ansible-workflow, config-management
Makefile                  make help for all targets
```

---

## Terraform Workflow (Quick Reference)

```bash
# First-time setup
cp config/sandbox.yml.example config/sandbox.yml
# Edit config/sandbox.yml with your values
make configure               # generates tfvars, inventory, ansible.cfg, envrc
# Fill in secrets in .envrc (API token, MinIO keys)
direnv allow

# Sandbox — init once, then plan+apply
make init                    # initializes with tfstate-sandbox bucket
make plan                    # terraform plan -var-file=sandbox.tfvars -out=sandbox.tfplan
make apply                   # terraform apply sandbox.tfplan

# Deploy / verify per component (pattern rules over discovery)
make ansible-<component>     # e.g. make ansible-pki
make verify-all              # every enabled component's verify.sh, hard gate
make examples                # reassemble config/*.yml.example from fragments

# Production — plan only, operator applies
make plan ENV=production     # reinits with tfstate-production, plans production.tfvars
```

Full workflow detail: see `.claude/skills/tf-plan-apply/SKILL.md`

---

## Available Skills

The workflow is design-record-driven: `/design` ends in a record, operator agreement on
the record is the go, execution is direct (or `/free-run` for long autonomous runs),
and behavioral verification (`make verify-all`, `/sanity-sweep`) closes the loop.
There are no plan→generate→review pipelines.

| Skill | Purpose |
|---|---|
| `/design <rough idea>` | Explore and decide a design — one decision at a time → committed design record (incl. execution boundary for autonomous runs) |
| `/free-run <record>` | Execute an agreed design record autonomously — journaled, per-slice commits, verify gates, failures journaled as lessons |
| `/review [files]` | Single-pass review with tf-reviewer — security, bpg/proxmox correctness, component-architecture fit |
| `/handoff` | Package production plan with context for operator handoff |
| `/assess <scope + concerns>` | Structured project assessment with discussion |
| `/sanity-sweep` | Tier-2 judgment sweep over deployed components — record-only |
| `/retro` | Retrospective on a completed session — surfaces prompting lessons, recommends no action / memory / skill update / new skill |
| `/day2-ops` | Resize, snapshot, or reconfigure existing VMs/LXCs (config edits, never `.tf` edits) |

---

## Agent-Host Conventions

### SSH from Claude Code (`sandbox-ssh`)
`sandbox-ssh` and `sandbox-scp` are shell aliases on the agent host that map
to plain `ssh`/`scp`. They exist solely to bypass Claude Code's `Bash(ssh *)` / `Bash(scp *)`
deny rules in `.claude/settings.json`, which restrict arbitrary SSH from Bash tool calls.

- **Use `sandbox-ssh`** in Bash tool calls when SSHing to sandbox hosts (e.g. fetching checksums, testing connectivity)
- **Never** put `sandbox-ssh` in `ansible.cfg`, scripts, or docs — those run outside Claude Code's permission layer and must use plain `ssh`

---

## Debugging and Investigation

When diagnosing a problem, distinguish confidence level explicitly:

- **Known** — directly observed: a code line, API response, error message, or test result
- **Hypothesised** — inferred from general knowledge, not yet verified on this system

If a root cause explanation has no direct evidence citation, flag it as a hypothesis and propose verification before acting. In this repo, verification almost always means hitting the Proxmox API directly, reading a specific config, or checking a log — not reasoning from general knowledge about how Proxmox or bpg/proxmox typically behaves.

> Signal to shift into investigation mode: "Can we verify that directly?"

---

## Key Constraints Checklist

Before any commit:
- [ ] `.envrc` is not staged (`git status` shows it untracked/ignored)
- [ ] `config/*.yml` (not `.example`) is not staged
- [ ] No `*.tfstate`, `*.tfvars`, or `*.tfplan` files staged
- [ ] No credentials or IPs hardcoded in any `.tf` file
- [ ] `.devcontainer/` untouched (retired; awaiting operator-reviewed deletion)
- [ ] `make lint` passes (tflint + ansible-lint)
- [ ] Any `terraform apply` in this session targeted sandbox only
- [ ] Any new/modified doc files contain no firewall product names, VLAN IDs, IPs, or internal hostnames — intent level only (public repo)
