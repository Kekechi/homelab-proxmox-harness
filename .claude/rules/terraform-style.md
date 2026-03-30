---
paths:
  - "terraform/**/*.tf"
  - "terraform/**/*.tfvars*"
---

# Terraform Style Rules

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
