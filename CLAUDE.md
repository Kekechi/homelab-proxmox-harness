# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

Homelab Proxmox Private Cloud managed with Terraform (`bpg/proxmox` v0.99.0+) and Ansible.
State backend: MinIO (self-hosted S3, LXC on Proxmox) with a GitLab HTTP migration path.
Claude Code runs inside a dev container with a Squid forward proxy for network isolation.

---

## Explicit Prohibitions

- **NEVER** modify files under `.devcontainer/` autonomously — Squid config is baked into the image; changes only take effect after operator rebuilds. Exception: `make configure` may regenerate `allowed-cidrs.conf`. **Operator-directed edits are permitted when the operator explicitly requests them** (i.e. "edit this file", not inferred intent).
- **NEVER** run `terraform apply` without a plan file (`terraform plan -out=<file>` first)
- **NEVER** apply Terraform for production — produce a plan file and hand it to the operator
- **NEVER** commit `.envrc`, `config/*.yml`, or any file containing tokens, passwords, or secret keys
- **NEVER** bypass the proxy or modify network configuration
- **NEVER** edit generated files directly (`terraform/*.tfvars`, `ansible/inventory/hosts.yml`, `.devcontainer/squid/allowed-cidrs.conf`) — regenerate via `make configure`

---

## Environment Model

| Environment | Config file | Claude may apply? | State bucket |
|---|---|---|---|
| **sandbox** | `config/sandbox.yml` | Yes — plan-file required | `tfstate-sandbox` |
| **production** | `config/production.yml` | No — plan only | `tfstate-production` |

Switch environments with `ENV=`: `make plan ENV=production`
Production token (`operator-production`) is not in the dev container — applies would fail at auth. This is intentional.

---

## Repository Structure

```
config/
  sandbox.yml.example     Centralized config template (copy → sandbox.yml, run make configure)
  production.yml.example
.devcontainer/            Dev container + Squid proxy config (do not modify directly)
terraform/
  main.tf                 Provider block + module calls
  versions.tf             Required version + provider pins
  variables.tf            Unified variables (sandbox superset)
  backend.tf              S3 backend — bucket passed at terraform init time
  modules/
    proxmox-vm/           proxmox_virtual_environment_vm
    proxmox-lxc/          proxmox_virtual_environment_container
    proxmox-network/      proxmox_virtual_environment_network_linux_bridge
ansible/
  ansible.cfg             SSH ProxyCommand through Squid CONNECT
  inventory/
    hosts.yml             Generated — do not edit (run make configure)
    group_vars/all/       vault.yml.example for ansible vault secrets
  roles/                  common, minio
  playbooks/
scripts/
  generate-configs.py     Generates tfvars/inventory/envrc/allowed-cidrs from config YAML
  bootstrap-minio.sh      One-time MinIO bucket + IAM setup
  verify-isolation.sh     Network isolation verification
docs/                     proxmox-iam.md, minio-setup.md, network-policy.md, threat-model.md
.claude/
  agents/                 iac-planner, iac-generator, tf-reviewer
  skills/                 tf-plan-apply, proxmox-module, sandbox-deploy, tf-troubleshoot, day2-ops
  commands/               /plan, /generate, /deploy, /review, /handoff
  rules/                  sandbox-isolation, terraform-style, iam-model, network-policy,
                          ansible-workflow, config-management
Makefile                  make help for all targets
```

---

## Terraform Workflow (Quick Reference)

```bash
# First-time setup
cp config/sandbox.yml.example config/sandbox.yml
# Edit config/sandbox.yml with your values
make configure               # generates tfvars, inventory, envrc, allowed-cidrs
# Fill in secrets in .envrc (API token, MinIO keys)
direnv allow

# Sandbox — init once, then plan+apply
make init                    # initializes with tfstate-sandbox bucket
make plan                    # terraform plan -var-file=sandbox.tfvars -out=sandbox.tfplan
make apply                   # terraform apply sandbox.tfplan

# Production — plan only, operator applies
make plan ENV=production     # reinits with tfstate-production, plans production.tfvars
```

Full workflow detail: see `.claude/skills/tf-plan-apply/SKILL.md`

---

## Available Commands

| Command | Purpose |
|---|---|
| `/plan <description>` | Plan infrastructure change using iac-planner (Opus) |
| `/generate` | Write code from an approved plan using iac-generator |
| `/deploy <description>` | Full plan → generate → review → apply pipeline |
| `/review [files]` | Review Terraform/Ansible code with tf-reviewer |
| `/handoff` | Package production plan with context for operator handoff |

---

## Dev Container Conventions

### SSH from Claude Code (`sandbox-ssh`)
`sandbox-ssh` and `sandbox-scp` are shell aliases (defined in `.devcontainer/Dockerfile`) that map
to plain `ssh`/`scp`. They exist solely to bypass Claude Code's `Bash(ssh *)` / `Bash(scp *)`
deny rules in `.claude/settings.json`, which restrict arbitrary SSH from Bash tool calls.

- **Use `sandbox-ssh`** in Bash tool calls when SSHing to sandbox hosts (e.g. fetching checksums, testing connectivity)
- **Never** put `sandbox-ssh` in `ansible.cfg`, scripts, or docs — those run outside Claude Code's permission layer and must use plain `ssh`

---

## Key Constraints Checklist

Before any commit:
- [ ] `.envrc` is not staged (`git status` shows it untracked/ignored)
- [ ] `config/*.yml` (not `.example`) is not staged
- [ ] No `*.tfstate`, `*.tfvars`, or `*.tfplan` files staged
- [ ] No credentials or IPs hardcoded in any `.tf` file
- [ ] `.devcontainer/` changes are operator-directed (not autonomous) and flagged for rebuild (except `allowed-cidrs.conf` from `make configure`)
- [ ] `make lint` passes (tflint + ansible-lint)
- [ ] Any `terraform apply` in this session targeted sandbox only
