---
name: proxmox-module
description: bpg/proxmox provider module authoring patterns for homelab VMs, LXCs, and networks. Covers resource names, required arguments, cloud-init, VLAN, pool scoping, and common pitfalls.
---

# Skill: Proxmox Module Authoring

## When to Activate

- Writing or modifying terraform modules under `terraform/modules/`
- Adding a new VM, LXC, or network bridge resource
- Debugging bpg/proxmox provider errors
- Reviewing module outputs for Ansible inventory consumption

## Resource Name Reference

| What | Resource Type |
|---|---|
| Virtual Machine | `proxmox_virtual_environment_vm` |
| LXC Container | `proxmox_virtual_environment_container` |
| Linux Bridge | `proxmox_virtual_environment_network_linux_bridge` |
| Cloud-init snippet | `proxmox_virtual_environment_file` |
| Pool | `proxmox_virtual_environment_pool` — requires `Pool.Allocate`, Claude cannot create |

## VM Module Pattern (`proxmox_virtual_environment_vm`)

```hcl
resource "proxmox_virtual_environment_vm" "this" {
  node_name = var.node_name
  vm_id     = var.vm_id
  name      = var.vm_name
  pool_id   = var.pool_id  # REQUIRED — enforces sandbox isolation

  stop_on_destroy = true   # REQUIRED — prevents orphaned running VMs

  cpu {
    cores = var.cores
    type  = "x86-64-v2-AES"  # homelab standard; supports most modern Linux
  }

  memory {
    dedicated = var.memory_mb
  }

  disk {
    interface    = "scsi0"
    size         = var.disk_size_gb
    datastore_id = var.datastore_id
    iothread     = true   # performance — enable for virtio-scsi-single
    discard      = "on"   # TRIM support for SSDs
  }

  network_device {
    bridge = var.bridge
    model  = "virtio"
    vlan_id = var.vlan_id  # null = untagged
  }

  # Clone from template (omit block entirely if creating from scratch)
  dynamic "clone" {
    for_each = var.clone_template_id != 0 ? [1] : []
    content {
      vm_id = var.clone_template_id
      full  = true
    }
  }

  # Cloud-init
  initialization {
    ip_config {
      ipv4 {
        # Static: "192.168.20.x/24" | DHCP: "dhcp"
        address = var.ipv4_address != "" ? var.ipv4_address : "dhcp"
        gateway = var.ipv4_address != "" ? var.ipv4_gateway : null
      }
    }
    user_account {
      keys = var.ssh_public_key != "" ? [var.ssh_public_key] : []
    }
  }

  agent {
    enabled = true  # enables qemu-guest-agent (required for IP reporting)
  }
}
```

## LXC Module Pattern (`proxmox_virtual_environment_container`)

Key differences from VMs:
- No `cpu.type` — LXCs inherit host CPU
- No `clone` block — use `template_file_id` (path to CT template in Proxmox storage)
- `unprivileged = true` is the safe default
- Network is `network_interface`, not `network_device`

```hcl
resource "proxmox_virtual_environment_container" "this" {
  node_name    = var.node_name
  vm_id        = var.vm_id
  pool_id      = var.pool_id  # REQUIRED
  unprivileged = true

  operating_system {
    template_file_id = var.template_file_id
    type             = var.os_type  # "ubuntu", "debian", etc.
  }

  cpu { cores = var.cores }

  memory {
    dedicated = var.memory_mb
    swap      = var.swap_mb
  }

  disk {
    datastore_id = var.datastore_id
    size         = var.disk_size_gb
  }

  network_interface {
    name    = "eth0"
    bridge  = var.bridge
    vlan_id = var.vlan_id
  }

  initialization {
    ip_config {
      ipv4 {
        address = var.ipv4_address != "" ? var.ipv4_address : "dhcp"
        gateway = var.ipv4_address != "" ? var.ipv4_gateway : null
      }
    }
  }
}
```

## Common Pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| `403 Forbidden` on all resources | Token ACL not set on `/pool/sandbox` | Run pveum ACL setup — see `docs/proxmox-iam.md` |
| VM created but IP never shows | `agent.enabled = false` or guest agent not running | Ensure template has qemu-guest-agent installed |
| `iothread` ignored | SCSI controller not `virtio-scsi-single` | Add `scsi_hardware = "virtio-scsi-single"` to VM |
| Clone hangs at 0% | Source template VM is running | Stop the template VM before cloning |
| `pool_id` rejected | Pool doesn't exist | Operator must create pool — `Pool.Allocate` required |
| `disk.size` shrinks | Cannot shrink disk in bpg/proxmox | Only increase disk size; resize is one-way |

## Outputs for Ansible Consumption

VMs report IP via qemu-guest-agent. The output needs a `depends_on` or `timeouts` to wait:

```hcl
output "ipv4_addresses" {
  description = "VM IPv4 addresses from qemu-guest-agent (may be empty until agent starts)"
  value       = proxmox_virtual_environment_vm.this.ipv4_addresses
}
```

For LXCs, the IP is static (configured at provision time) — read it from the `initialization.ip_config` variable rather than from provider output.
