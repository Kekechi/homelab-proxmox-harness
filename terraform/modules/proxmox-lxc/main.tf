resource "proxmox_virtual_environment_container" "this" {
  node_name     = var.node_name
  vm_id         = var.vm_id
  pool_id       = var.pool_id
  description   = var.description
  start_on_boot = var.start_on_boot
  unprivileged  = var.unprivileged
  started       = var.started
  # Note: proxmox_virtual_environment_container does not support stop_on_destroy
  # (confirmed against bpg/proxmox v0.99 — it is a VM-only argument).
  # Destroy behavior for a running container is provider-managed; verify in sandbox
  # before relying on clean destroy in production.

  console {
    enabled   = true
    type      = "console"
    tty_count = 2
  }

  initialization {
    hostname = var.hostname

    dynamic "ip_config" {
      for_each = var.ipv4_address != null ? [1] : []
      content {
        ipv4 {
          address = var.ipv4_address
          gateway = var.ipv4_gateway
        }
      }
    }

    dynamic "ip_config" {
      for_each = var.ipv4_address == null ? [1] : []
      content {
        ipv4 {
          address = "dhcp"
          # gateway assigned by DHCP — intentionally omitted
        }
      }
    }

    user_account {
      password = var.root_password
      keys     = length(var.ssh_public_keys) > 0 ? var.ssh_public_keys : null
    }
  }

  cpu {
    cores = var.cores
    # LXC containers inherit the host CPU — no type argument exists for containers
    # (unlike proxmox_virtual_environment_vm which supports cpu.type = "x86-64-v2-AES").
  }

  memory {
    dedicated = var.memory_mb
    swap      = var.swap_mb
  }

  disk {
    datastore_id = var.datastore_id
    size         = var.disk_size_gb
  }

  lifecycle {
    precondition {
      condition     = var.root_password != null || length(var.ssh_public_keys) > 0
      error_message = "At least one authentication method must be provided: set root_password or ssh_public_keys."
    }
  }

  network_interface {
    name    = "eth0"
    bridge  = var.bridge
    vlan_id = var.vlan_id
  }

  operating_system {
    template_file_id = var.template_file_id
    type             = var.os_type
  }
}
