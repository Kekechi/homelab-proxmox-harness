---
name: day2-ops
description: Day-2 operations for existing Proxmox VMs and LXCs. Covers resize (disk, memory, CPU), snapshots, network changes, cloud-init reconfiguration, and bpg/proxmox modify constraints.
---

# Skill: Day-2 Operations

## When to Activate

- Resizing an existing VM or LXC (disk, memory, CPU)
- Managing Proxmox snapshots via Terraform
- Adding or modifying network interfaces on running resources
- Changing cloud-init configuration on existing VMs
- Modifying any resource that was previously deployed via the PGE pipeline

<!-- Modify operations have non-obvious bpg/proxmox constraints that differ from creation.
     See .claude/skills/proxmox-module/SKILL.md for creation patterns. -->

## General Modify Workflow

Day-2 changes follow the same plan-file workflow as day-1:

1. Edit the module call or variables in `terraform/main.tf` / `terraform/variables.tf`
2. `terraform plan -var-file=sandbox.tfvars -out=sandbox.tfplan`
3. **Review the plan carefully** — some changes are destructive (force replacement)
4. `terraform apply sandbox.tfplan`

**Critical:** Always check the plan output for `# forces replacement`. This means the resource will be destroyed and recreated, not modified in-place.

## VM Resize Operations

### Disk Resize

**Constraint:** Disks can only grow, never shrink. Attempting to reduce `disk.size` will fail.

```hcl
# Before: 32GB → After: 64GB (works)
disk {
  interface    = "scsi0"
  size         = 64  # was 32
  datastore_id = var.datastore_id
  iothread     = true
  discard      = "on"
}
```

**Behavior:** In-place resize. No VM restart needed for disk growth (guest OS may need `growpart` + `resize2fs`).

**Plan output will show:**
```
~ disk.0.size = 32 -> 64
```

### Memory Resize

**Constraint:** Memory changes take effect on next boot unless the VM supports hotplug.

```hcl
memory {
  dedicated = 4096  # was 2048
}
```

**Behavior:**
- If memory is increased moderately: may apply without restart (if qemu supports balloon)
- If memory is changed significantly: plan may show `~ reboot = true` or require manual restart
- bpg/proxmox applies memory changes to the VM config; guest sees it after reboot

**Plan output will show:**
```
~ memory.0.dedicated = 2048 -> 4096
```

### CPU Resize

**Constraint:** Core count changes take effect on next boot.

```hcl
cpu {
  cores = 4  # was 2
  type  = "x86-64-v2-AES"
}
```

**Behavior:** Config updated immediately, guest sees new cores after reboot.

**Warning:** Changing `cpu.type` forces replacement on some provider versions. Do not change CPU type on existing VMs unless replacement is acceptable.

## LXC Resize Operations

LXC containers are more flexible than VMs for resize:

- **Disk:** Grow only, same as VM. `pct resize` happens online.
- **Memory:** Changes apply immediately (no reboot needed for LXCs).
- **CPU cores:** Changes apply immediately.

```hcl
cpu { cores = 4 }       # immediate
memory { dedicated = 4096 }  # immediate
disk { size = 64 }      # grow only, immediate
```

## Snapshot Management

### Creating Snapshots via Terraform

**Constraint:** bpg/proxmox v0.99.0+ does NOT have a dedicated snapshot resource. Snapshots are managed outside Terraform.

**Recommended workflow for sandbox VMs:**
```bash
# Take snapshot via Proxmox API (read: non-destructive)
curl -sk -X POST \
  -H "Authorization: PVEAPIToken=$PROXMOX_VE_API_TOKEN" \
  "$PROXMOX_VE_ENDPOINT/api2/json/nodes/<node>/qemu/<vmid>/snapshot" \
  -d "snapname=pre-change" -d "description=Before day-2 modification"

# List snapshots
curl -sk \
  -H "Authorization: PVEAPIToken=$PROXMOX_VE_API_TOKEN" \
  "$PROXMOX_VE_ENDPOINT/api2/json/nodes/<node>/qemu/<vmid>/snapshot"
```

**Before risky day-2 changes:** Always take a snapshot so the operator can rollback if needed.

**Note:** `stop_on_destroy = true` means Terraform will stop the VM before destroying it, but snapshots are independent of Terraform lifecycle.

## Network Interface Changes

### Adding a Network Interface

```hcl
# Additional NIC (existing VMs)
network_device {
  bridge  = var.bridge
  model   = "virtio"
  vlan_id = var.vlan_id
}

# Second NIC
network_device {
  bridge  = "vmbr1"
  model   = "virtio"
  vlan_id = var.vlan_id_mgmt
}
```

**Behavior:** Adding a NIC is non-destructive. The guest OS needs to configure the new interface (DHCP or static via cloud-init/Ansible).

### Changing VLAN

**Warning:** Changing `vlan_id` on an existing interface changes the network — the VM will lose connectivity on the old VLAN. Plan this carefully.

```
~ network_device.0.vlan_id = 20 -> 30
```

**Pre-change checklist:**
- [ ] New VLAN CIDR is in `allowed-cidrs.conf` (for SSH via Squid)
- [ ] Update `config/sandbox.yml` with new IP if static
- [ ] Run `make configure` after apply to regenerate inventory

## Cloud-Init Reconfiguration

### Changing Static IP

```hcl
initialization {
  ip_config {
    ipv4 {
      address = "192.168.20.60/24"  # was .50
      gateway = "192.168.20.1"
    }
  }
}
```

**Warning:** Cloud-init only runs on first boot by default. Changing cloud-init config in Terraform updates the Proxmox config but the guest may not pick it up without:
1. Clearing cloud-init state: `sudo cloud-init clean` inside the VM
2. Rebooting the VM

**Better approach for IP changes on running VMs:** Use Ansible to reconfigure networking directly rather than cloud-init.

### Changing SSH Keys

```hcl
initialization {
  user_account {
    keys = [var.ssh_public_key_new]
  }
}
```

**Same cloud-init caveat:** Keys are only written on first boot. Use Ansible `authorized_key` module for running VMs.

## Destructive vs Non-Destructive Changes

| Change | Behavior | Restart Needed? |
|---|---|---|
| Disk grow | In-place | No (guest needs resize) |
| Disk shrink | **FAILS** | N/A |
| Memory increase | Config update | Usually yes |
| CPU cores change | Config update | Yes |
| CPU type change | **Forces replacement** | N/A (new VM) |
| Add NIC | In-place | No (guest config needed) |
| Change VLAN | In-place | No (connectivity changes) |
| Change cloud-init IP | Config update | Yes + cloud-init clean |
| Change `pool_id` | **Not possible** — Pool.Allocate required | N/A |
| Change `node_name` | **Forces replacement** (migration) | N/A (new VM) |
| Change `vm_id` | **Forces replacement** | N/A (new VM) |

## Post-Modify Checklist

After any day-2 change:
- [ ] Plan output reviewed for `# forces replacement` (none unexpected)
- [ ] `terraform state list` shows expected resources
- [ ] VM/LXC accessible via SSH through Squid
- [ ] If IP changed: `config/sandbox.yml` updated, `make configure` run, inventory regenerated
- [ ] If network changed: `allowed-cidrs.conf` includes new CIDR
- [ ] Ansible can still reach the host (`ansible sandbox -m ping`)
