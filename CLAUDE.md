# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

Homelab Proxmox Private Cloud managed with Terraform (`bpg/proxmox` v0.99.0+) and Ansible.
State backend: MinIO (self-hosted S3, LXC on Proxmox) with a GitLab HTTP migration path.
Claude Code runs inside a dev container with a Squid forward proxy for network isolation.

---

## Explicit Prohibitions

- **NEVER** modify files under `.devcontainer/` — Squid config is baked into the image; changes only take effect after operator rebuilds
- **NEVER** run `terraform apply` without a plan file (`terraform plan -out=<file>` first)
- **NEVER** apply Terraform for production — produce a plan file and hand it to the operator
- **NEVER** commit `.envrc` or any file containing tokens, passwords, or secret keys
- **NEVER** bypass the proxy or modify network configuration

---

## Environment Model

| Environment | Var-file | Claude may apply? | State bucket |
|---|---|---|---|
| **sandbox** | `sandbox.tfvars` | Yes — plan-file required | `tfstate-sandbox` |
| **production** | `production.tfvars` | No — plan only | `tfstate-production` |

Production token (`operator-production`) is not in the dev container — applies would fail at auth. This is intentional.

---

## Repository Structure

```
.devcontainer/          Dev container + Squid proxy config (do not modify)
terraform/
  main.tf               Provider block + module calls
  versions.tf           Required version + provider pins
  variables.tf          Unified variables (sandbox superset)
  backend.tf            S3 backend — bucket passed at terraform init time
  sandbox.tfvars.example
  production.tfvars.example
  modules/
    proxmox-vm/         proxmox_virtual_environment_vm
    proxmox-lxc/        proxmox_virtual_environment_container
    proxmox-network/    proxmox_virtual_environment_network_linux_bridge
ansible/
  ansible.cfg           SSH ProxyCommand through Squid CONNECT
  inventory/            Per-environment host inventories
  roles/                common, minio
  playbooks/
scripts/
  bootstrap-minio.sh    One-time MinIO bucket + IAM setup
  verify-isolation.sh   Network isolation verification
docs/                   proxmox-iam.md, minio-setup.md, network-policy.md, threat-model.md
.claude/
  agents/               iac-planner, iac-generator, tf-reviewer, sandbox-guard
  skills/               tf-plan-apply, proxmox-module, sandbox-deploy
  commands/             /plan, /deploy, /review
  rules/                sandbox-isolation, terraform-style, iam-model, network-policy, ansible-workflow
Makefile                make help for all targets
```

---

## Terraform Workflow (Quick Reference)

```bash
# Sandbox — init once, then plan+apply
make init                    # initializes with tfstate-sandbox bucket
make plan                    # terraform plan -var-file=sandbox.tfvars -out=sandbox.tfplan
make apply                   # terraform apply sandbox.tfplan

# Production — plan only, operator applies
make plan-prod               # reinits with tfstate-production, plans production.tfvars
```

Full workflow detail: see `.claude/skills/tf-plan-apply/SKILL.md`

---

## Available Commands

| Command | Purpose |
|---|---|
| `/plan <description>` | Plan infrastructure change using iac-planner (Opus) |
| `/deploy <description>` | Full plan → generate → review → apply pipeline |
| `/review [files]` | Review Terraform/Ansible code with tf-reviewer |

---

## Key Constraints Checklist

Before any commit:
- [ ] `.envrc` is not staged (`git status` shows it untracked/ignored)
- [ ] No `*.tfstate`, `*.tfvars`, or `*.tfplan` files staged
- [ ] No credentials or IPs hardcoded in any `.tf` file
- [ ] `.devcontainer/` changes flagged for operator review
- [ ] `make lint` passes (tflint + ansible-lint)
- [ ] Any `terraform apply` in this session targeted sandbox only
