# day2-ops

Modify existing Proxmox VMs and LXCs that were previously deployed. Covers resize operations, snapshots, network interface changes, and cloud-init reconfiguration — with the bpg/proxmox-specific constraints for each.

Use this skill when you need to change something on a running resource. For deploying something new, use `/deploy` instead.

## Usage

```
/day2-ops
```

Then describe what you want to change, e.g.:
- "Grow the disk on vm-nginx from 32GB to 64GB"
- "Add a second NIC on VLAN 30 to vm-app"
- "Increase memory on lxc-minio from 2GB to 4GB"

## What it covers

### Resize

| Resource | Change | Behavior |
|---|---|---|
| VM disk | Grow only | In-place, no restart (guest needs `growpart`) |
| VM memory | Increase/decrease | Config update; takes effect on reboot |
| VM CPU cores | Increase/decrease | Config update; takes effect on reboot |
| VM CPU type | Change | **Forces replacement** — avoid on running VMs |
| LXC disk | Grow only | In-place, immediate |
| LXC memory | Any | Immediate, no reboot |
| LXC CPU cores | Any | Immediate, no reboot |

### Snapshots

bpg/proxmox v0.99.0+ has no Terraform snapshot resource. Snapshots are taken via the Proxmox API directly. The skill provides the curl commands to create and list snapshots — useful as a safety net before risky changes.

### Network interface changes

- **Adding a NIC** — non-destructive; guest OS needs to configure the new interface
- **Changing VLAN** — in-place, but the VM loses connectivity on the old VLAN immediately

### Cloud-init reconfiguration

Cloud-init only runs on first boot. Changing IP or SSH keys in Terraform updates the Proxmox config but the guest won't pick it up until `cloud-init clean` + reboot. For running VMs, Ansible is usually the better tool for these changes.

## Important: check for `# forces replacement`

Always review the `terraform plan` output before applying. Some changes silently force the VM to be destroyed and recreated:

- Changing `cpu.type`
- Changing `node_name` (triggers live migration or replacement)
- Changing `vm_id`

If you see `# forces replacement` on a production-like VM, stop and discuss with the operator before applying.

## Workflow

1. Edit the module call or variable in `terraform/main.tf` / `terraform/variables.tf`
2. `make plan` — review carefully for unexpected replacements
3. `make apply`
4. If IP or network changed: update `config/sandbox.yml`, run `make configure`
