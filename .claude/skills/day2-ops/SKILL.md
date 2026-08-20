---
name: day2-ops
description: Day-2 operations for existing Proxmox VMs and LXCs. Covers resize (disk, memory, CPU), snapshots, network changes, cloud-init reconfiguration, and bpg/proxmox modify constraints.
disable-model-invocation: true
---

# Skill: Day-2 Operations

## When to Activate

- Resizing an existing VM or LXC (disk, memory, CPU)
- Managing Proxmox snapshots
- Network or cloud-init changes on running resources
- Modifying any previously deployed instance

<!-- Modify operations have non-obvious bpg/proxmox constraints that differ from creation.
     See .claude/skills/proxmox-module/SKILL.md for creation patterns. -->

## General Modify Workflow

Day-2 changes are **config changes**, not `.tf` edits — the root module is generic and
instance values flow from config through the generator:

1. Edit the value at its source:
   - **Sizing** (`cores`, `memory_mb`, `disk_gb`): per-env override in the service's
     `config/<env>.yml` block, or the manifest's `resources:` default in
     `components/<name>/component.yml` if the change should apply everywhere
   - **IP / network / node**: the service's block in `config/<env>.yml`
2. `make configure` — regenerates tfvars (and inventory if addressing changed)
3. `make plan` — **review the plan carefully** for `# forces replacement`; some changes
   destroy and recreate rather than modify in place
4. `make apply`

**Critical:** Always check the plan output for `# forces replacement` before applying.

## VM Resize Operations

### Disk Resize

**Constraint:** Disks can only grow, never shrink. A reduced disk size fails at apply.

**Behavior:** In-place resize; no VM restart needed for growth (the guest OS may need
`growpart` + `resize2fs`). Plan shows `~ disk.0.size = 32 -> 64`.

### Memory Resize

**Constraint:** Memory changes take effect on next boot unless the VM supports hotplug
(balloon may absorb moderate increases without restart). Plan shows
`~ memory.0.dedicated = 2048 -> 4096`; the guest sees it after reboot.

### CPU Resize

**Constraint:** Core-count changes take effect on next boot.

**Warning:** Changing the CPU *type* forces replacement on some provider versions. The
type is pinned repo-wide (`x86-64-v2-AES`, terraform-style.md) — do not change it on
existing VMs unless replacement is acceptable.

## LXC Resize Operations

LXC containers are more flexible: memory and CPU-core changes apply immediately (no
reboot); disk is grow-only like VMs but resizes online.

## Snapshot Management

**Constraint:** bpg/proxmox v0.99.0+ has NO dedicated snapshot resource. Snapshots are
managed outside Terraform, via the Proxmox API (the sandbox token has `VM.Snapshot` /
`VM.Snapshot.Rollback`):

```bash
# Take a snapshot (non-destructive)
curl -sk -X POST \
  -H "Authorization: PVEAPIToken=$PROXMOX_VE_API_TOKEN" \
  "$PROXMOX_VE_ENDPOINT/api2/json/nodes/<node>/qemu/<vmid>/snapshot" \
  -d "snapname=pre-change" -d "description=Before day-2 modification"

# List snapshots
curl -sk \
  -H "Authorization: PVEAPIToken=$PROXMOX_VE_API_TOKEN" \
  "$PROXMOX_VE_ENDPOINT/api2/json/nodes/<node>/qemu/<vmid>/snapshot"
```

**Before risky day-2 changes:** take a snapshot so the operator can roll back.

**Note:** `stop_on_destroy = true` means Terraform stops the VM before destroying it;
snapshots are independent of the Terraform lifecycle.

## Network Changes

- **Moving a service to another network:** change the service's `network:` reference in
  `config/<env>.yml` (the target must exist under `infrastructure.networks`), update its
  `ip` to an address in the new subnet, then `make configure` + plan + apply.
  **Warning:** the instance loses connectivity on the old network at apply — plan the
  Ansible follow-up before applying.
- **Additional NICs:** the typed services map models one NIC per instance. A second NIC
  is a primitive-module interface change (core change) — treat it as a design item, not
  a day-2 tweak.

## Cloud-Init Reconfiguration

**Warning:** cloud-init runs on first boot only. Changing cloud-init-delivered values
(static IP, SSH keys) in config updates the Proxmox side, but the guest won't pick it up
without `sudo cloud-init clean` + reboot — and depending on the provider version it may
force replacement.

**Better approach on running instances:** reconfigure via Ansible (networking directly;
`ansible.builtin.authorized_key` for keys). Reserve cloud-init changes for rebuilds.

## Destructive vs Non-Destructive Changes

| Change | Behavior | Restart Needed? |
|---|---|---|
| Disk grow | In-place | No (guest needs resize) |
| Disk shrink | **FAILS** | N/A |
| Memory increase | Config update | Usually yes |
| CPU cores change | Config update | Yes |
| CPU type change | **Forces replacement** | N/A (new VM) |
| Change network/VLAN | In-place | No (connectivity changes) |
| Change cloud-init IP | Config update | Yes + cloud-init clean |
| Change `pool_id` | **Not possible** — Pool.Allocate required | N/A |
| Change `node` | **Forces replacement** (migration) | N/A (new VM) |
| Change `vm_id` / `ct_id` | **Forces replacement** | N/A (new VM) |

## Post-Modify Checklist

After any day-2 change:
- [ ] Plan output reviewed for `# forces replacement` (none unexpected)
- [ ] `terraform state list` shows expected resources
- [ ] If IP/network changed: `make configure` re-run so inventory matches reality
- [ ] Ansible can still reach the host (`ansible <group> -m ping` from `ansible/`)
- [ ] `make verify-<component>` passes for the touched component
