resource "proxmox_virtual_environment_vm" "this" {
  name      = var.vm_name
  vm_id     = var.vm_id
  node_name = var.node_name
  pool_id   = var.pool_id
  started   = var.started
  on_boot   = var.start_on_boot

  # Clone from template if template ID is provided
  dynamic "clone" {
    for_each = var.clone_template_id != 0 ? [1] : []
    content {
      vm_id        = var.clone_template_id
      full         = true
      retries      = 3
      datastore_id = var.datastore_id
    }
  }

  cpu {
    cores = var.cores
    type  = var.cpu_type
  }

  memory {
    dedicated = var.memory_mb
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = var.disk_size_gb
    discard      = "on"
    iothread     = true
  }

  network_device {
    bridge  = var.bridge
    model   = "virtio"
    vlan_id = var.vlan_id
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id = var.cloudinit_datastore_id
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
        }
      }
    }

    dynamic "dns" {
      for_each = length(var.dns_servers) > 0 ? [1] : []
      content {
        servers = var.dns_servers
      }
    }

    dynamic "user_account" {
      for_each = var.ssh_public_key != null ? [1] : []
      content {
        keys = [var.ssh_public_key]
      }
    }
  }

  agent {
    enabled = var.agent_enabled
  }

  stop_on_destroy = true
}
