# day2-ops

Modify existing Proxmox VMs and LXCs that were previously deployed. Covers resize operations, snapshots, network changes, and cloud-init reconfiguration — with the bpg/proxmox-specific constraints for each.

Use this skill when you need to change something on a running resource. For deploying something new, add a component (see `components/CLAUDE.md`).

## Usage

```
/day2-ops
```

Then describe what you want to change, e.g.:
- "Grow the disk on the nexus LXC from 32GB to 64GB"
- "Increase memory on the minio LXC from 2GB to 4GB"
- "Move the dns dist instance to the mgmt network"

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

### Network changes

- **Moving to another network** — change the service's `network:` + `ip` in config; connectivity on the old network drops at apply
- **Additional NICs** — not modeled by the typed services map; a primitive-module interface change, treat as a design item

### Cloud-init reconfiguration

Cloud-init only runs on first boot. Changing IP or SSH keys in config updates the Proxmox side but the guest won't pick it up until `cloud-init clean` + reboot. For running instances, Ansible is usually the better tool for these changes.

## Important: check for `# forces replacement`

Always review the `make plan` output before applying. Some changes silently force the VM to be destroyed and recreated:

- Changing CPU type
- Changing `node` (triggers migration or replacement)
- Changing `vm_id` / `ct_id`

If you see `# forces replacement` you didn't expect, stop and discuss with the operator before applying.

## Workflow

1. Edit the value at its source: the service's block in `config/<env>.yml` (sizing may also live in the component manifest's `resources:` default)
2. `make configure` — regenerate tfvars/inventory
3. `make plan` — review carefully for unexpected replacements
4. `make apply`
5. `make verify-<component>` for the touched component
