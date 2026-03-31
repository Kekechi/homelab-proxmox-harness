# Sandbox Isolation Rules

These rules are always active. They enforce the safety boundary between Claude's sandbox access and the production environment.

## Terraform Constraints

- NEVER run `terraform apply` without a plan file — always `terraform plan -out=<file>` first
- NEVER apply Terraform for production — generate a plan and hand it to the operator
- All module calls MUST pass `pool_id = var.pool_id` so resources land in the sandbox pool
- NEVER hardcode credentials, API tokens, or IPs in `.tf` files
- NEVER use `-target` to apply partial plans without explicit operator instruction

## File System Constraints

- NEVER modify files under `.devcontainer/` autonomously — Squid config is baked into the image and changes have no effect until the operator rebuilds
  - **Exception 1:** `make configure` may regenerate `.devcontainer/squid/allowed-cidrs.conf` as a downstream output of the centralized config system.
  - **Exception 2:** Operator-directed edits are permitted when the operator explicitly requests them (e.g. "edit this file") — not when intent is inferred.
  - The operator must run `make build` + reopen the container for any change to take effect.
- NEVER commit `.envrc`, `*.tfvars`, `*.tfstate`, or `*.tfplan` files
- NEVER write credentials to any file

## Network and IAM Constraints

- NEVER attempt to bypass the Squid proxy or modify network routing
- NEVER attempt to create Proxmox users, roles, or tokens — these require `Permissions.Modify` which Claude's role excludes
- NEVER attempt to move resources between pools — pool membership requires `Pool.Allocate` which Claude's role excludes

## State Constraints

- NEVER run `terraform state rm`, `terraform state mv`, or `terraform import` without explicit operator approval
- NEVER run `terraform force-unlock`
- NEVER delete the tfstate bucket or its objects
