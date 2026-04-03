---
paths:
  - "terraform/**/*.tf"
  - "terraform/**/*.tfvars*"
version: "1.0"
---

# Terraform Style Rules

<!-- Canonical source for bpg/proxmox conventions.
     These rules are also referenced inline in:
       .claude/agents/iac-generator.md
       .claude/agents/tf-reviewer.md
       .claude/skills/proxmox-module/SKILL.md
     Update all four files when changing any convention here. -->

## Provider and Version Pinning

- `required_version` and `required_providers` must be pinned in `versions.tf`
- Do not upgrade provider version without checking the bpg/proxmox changelog
- Commit `.terraform.lock.hcl` after `terraform init`

## Variables

- Every variable must have a `description`
- Sensitive variables (passwords, keys) must have `sensitive = true`
- Use `null` as default for optional values, not empty string `""`
- Variable names: snake_case, descriptive (not `v1`, `param`)

## Resources

- All VM/LXC resources: `stop_on_destroy = true` (prevents orphaned running VMs)
- All resources scoped to pool: `pool_id = var.pool_id`
- CPU type: `x86-64-v2-AES` for homelab hardware compatibility
- Disk interface: `scsi0` with `iothread = true`
- Network model: `virtio`

## Tags — Do Not Use

**Never set `tags` on any VM or LXC resource (`proxmox_virtual_environment_vm` or
`proxmox_virtual_environment_container`).**

Policy rationale: pool membership and resource naming provide sufficient organisation for
an IaC-managed homelab. Partial tagging (VMs only, not LXC) creates UI inconsistency
without adding value.

Technical background (LXC): Proxmox requires `VM.Config.Options` at `/vms/<id>` for
tags. During fresh LXC creation, this check fires before pool membership is established,
so pool ACL propagation cannot satisfy it — the entire creation POST is rejected with 403.
`onboot` and `description` do not share this restriction; only `tags` does.

If tags are ever needed: add them manually in the Proxmox UI after creation. Do not add
a `tags` variable to either module.

## Module Conventions

- Module source paths from root: `./modules/proxmox-vm`
- Every module must have `variables.tf`, `main.tf`, `outputs.tf`
- Credentials never pass through modules — provider reads from env vars

## bpg/proxmox Resource Names

| Resource | Correct name |
|---|---|
| Virtual Machine | `proxmox_virtual_environment_vm` |
| LXC Container | `proxmox_virtual_environment_container` |
| Network Bridge | `proxmox_virtual_environment_network_linux_bridge` |
| File (cloud-init) | `proxmox_virtual_environment_file` |
