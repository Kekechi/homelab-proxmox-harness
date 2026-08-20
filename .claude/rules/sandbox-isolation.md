# Sandbox Isolation Rules

These rules are always active. They enforce the safety boundary between Claude's
sandbox access and the production environment.

## Enforcement model

The hard boundary is IAM, not tooling: the agent host carries only the sandbox-scoped
Proxmox token and the sandbox MinIO key (see `iam-model.md`), so a production apply
fails at authentication — the production token is never present. There are no hook
guards; everything below is a working agreement layered on that boundary, and the
operator's pre-push review is the gate for anything leaving the machine.

## Terraform Constraints

- NEVER run `terraform apply` without a plan file — always `terraform plan -out=<file>` first
- NEVER apply Terraform for production — generate a plan and hand it to the operator (`/handoff`)
- NEVER run bare `terraform destroy` — use a destroy plan (`terraform plan -destroy -out=<file>`), sandbox only
- NEVER hardcode credentials, API tokens, or IPs in `.tf` files
- NEVER use `-target` to apply partial plans without explicit operator instruction
- The root module is generic: adding a service never adds a module block or variable —
  it adds a `components/<name>/` directory plus config (see `config-management.md`)

## File System Constraints

- NEVER edit generated files (they carry DO-NOT-EDIT headers): `terraform/<env>.tfvars`,
  `ansible/inventory/hosts.yml`, `ansible/ansible.cfg`, `.env.mk`, the non-secret
  `.envrc`, `config/*.yml.example` — edit `config/<env>.yml`, the component manifest,
  or the example fragments, then run `make configure` / `make examples`
- NEVER commit `.envrc`, `config/<env>.yml` (non-example), `*.tfvars`, `*.tfstate`, or `*.tfplan`
- NEVER write credentials to any file in the repo tree
- Public repo: committed docs and code stay at intent level — no internal IPs, hostnames,
  domain names, VLAN IDs, or firewall/security product names

## Network and IAM Constraints

- NEVER attempt to create Proxmox users, roles, or tokens — Claude's role excludes `Permissions.Modify`
- NEVER attempt to move resources between pools — pool membership requires `Pool.Allocate`, which Claude's role excludes
- The agent host's network position is part of the boundary — never modify its network
  configuration or probe networks outside the sandbox

## State Constraints

- NEVER run `terraform state rm`, `terraform state mv`, or `terraform import` without explicit operator approval
- NEVER run `terraform force-unlock`
- NEVER delete the tfstate bucket or its objects
