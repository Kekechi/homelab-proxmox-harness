# Proxmox IAM Setup

Run these commands on a Proxmox node as root. These are one-time bootstrap steps.

## Identity Model

| Identity | Token | ACL Paths | Role | Held By |
|---|---|---|---|---|
| Claude Code | `terraform@pve!claude-sandbox` | `/pool/sandbox`, `/storage/<id>` | `TerraformSandbox` | Dev container env var |
| Operator | `terraform@pve!operator-production` | `/` | `TerraformOperator` | Password manager |

---

## Privilege Reference

The following table maps each Proxmox privilege to the resource or operation that
requires it. Use this as justification for any future role changes.

| Privilege | Path scope | Required for |
|---|---|---|
| `VM.Allocate` | `/pool/<pool>` | Create, delete VMs and LXC containers |
| `VM.Clone` | `/pool/<pool>` | Clone a VM template into the pool |
| `VM.Audit` | `/pool/<pool>` | Read VM/LXC configuration and state |
| `VM.PowerMgmt` | `/pool/<pool>` | Start, stop, reboot VMs and containers |
| `VM.Config.CPU` | `/pool/<pool>` | Set cores, sockets, CPU type |
| `VM.Config.Memory` | `/pool/<pool>` | Set memory and balloon size |
| `VM.Config.Disk` | `/pool/<pool>` | Add/remove/resize disks, set boot order |
| `VM.Config.Network` | `/pool/<pool>` | Add/remove/modify network interfaces |
| `VM.Config.CDROM` | `/pool/<pool>` | Mount/eject ISO images |
| `VM.Config.HWType` | `/pool/<pool>` | Set machine type, ACPI, VGA |
| `VM.Config.Options` | `/pool/<pool>` | Set name, description, tags, OS type |
| `VM.Config.Cloudinit` | `/pool/<pool>` | Write cloud-init parameters |
| `VM.Console` | `/pool/<pool>` | Open VNC/SPICE/serial console |
| `VM.Monitor` | `/pool/<pool>` | QEMU monitor commands (QMP) |
| `VM.Snapshot` | `/pool/<pool>` | Create and delete snapshots |
| `VM.Snapshot.Rollback` | `/pool/<pool>` | Rollback to a snapshot |
| `VM.Migrate` | `/pool/<pool>` | Live-migrate VMs between nodes |
| `Datastore.AllocateSpace` | `/storage/<id>` | Write VM disk images and container rootfs |
| `Datastore.AllocateTemplate` | `/storage/<id>` | Download and store OS templates (LXC) |
| `Datastore.Audit` | `/storage/<id>` | List storage contents, read template names |
| `Pool.Audit` | `/pool/<pool>` | List pool members (read-only pool access) |
| `Pool.Allocate` | `/` | Create pools, add/remove pool members |
| `SDN.Use` | `/sdn` | Attach VMs/CTs to SDN-managed bridges |
| `Sys.Audit` | `/nodes/<node>` | Read node status, network config, logs |
| `Sys.Modify` | `/nodes/<node>` | **Create/modify/delete Linux bridges** |

**Intentionally excluded everywhere:** `Permissions.Modify`, `User.Modify`,
`Group.Allocate`, `Realm.Allocate`, `Sys.PowerMgmt`, `Sys.Console`.

### Network bridge constraint

`proxmox_virtual_environment_network_linux_bridge` requires `Sys.Modify` on
`/nodes/<node>`. This privilege is **node-scoped** — it cannot be granted via a pool
ACL and applies cluster-wide to the node, not just to sandbox resources. For this
reason `Sys.Modify` is excluded from the `TerraformSandbox` role and only the
operator token can manage network bridges.

If the sandbox needs a new bridge, the operator must create it manually or via the
production token, then reference it by name in sandbox VM/LXC configs.

---

## Step 1 — Create Proxmox User

Both tokens share a single Proxmox user in the `pve` realm (no shell login).

```bash
pveum user add terraform@pve --comment "Terraform service account"
```

---

## Step 2 — Claude's Role: TerraformSandbox

Minimal privileges for managing VMs and LXC containers within the sandbox pool.
Excludes all node-level, permission, and user management operations.

```bash
pveum role add TerraformSandbox \
  --privs "Datastore.AllocateSpace,Datastore.AllocateTemplate,Datastore.Audit,\
Pool.Audit,SDN.Use,\
VM.Allocate,VM.Audit,VM.Clone,\
VM.Config.CDROM,VM.Config.CPU,VM.Config.Cloudinit,VM.Config.Disk,\
VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,\
VM.Console,VM.Migrate,VM.Monitor,VM.PowerMgmt,\
VM.Snapshot,VM.Snapshot.Rollback"
```

**Deliberately excluded:** `Sys.Modify`, `Sys.Audit`, `Sys.PowerMgmt`,
`Permissions.Modify`, `User.Modify`, `Pool.Allocate`

---

## Step 3 — Operator's Role: TerraformOperator

Full VM, LXC, and network bridge management for production. Includes node-level
access required for Linux bridge creation.

```bash
pveum role add TerraformOperator \
  --privs "Datastore.AllocateSpace,Datastore.AllocateTemplate,Datastore.Audit,\
Pool.Allocate,Pool.Audit,SDN.Use,Sys.Audit,Sys.Modify,\
VM.Allocate,VM.Audit,VM.Clone,\
VM.Config.CDROM,VM.Config.CPU,VM.Config.Cloudinit,VM.Config.Disk,\
VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,\
VM.Console,VM.Migrate,VM.Monitor,VM.PowerMgmt,\
VM.Snapshot,VM.Snapshot.Rollback"
```

---

## Step 4 — Create Sandbox Pool

Resources managed by Claude Code are placed in this pool. The pool must exist before
granting the ACL.

```bash
pveum pool add sandbox --comment "Sandbox resources managed by Claude Code / Terraform"
```

---

## Step 5 — Claude's Token: claude-sandbox

The sandbox token requires **two ACL grants**: one on the pool (for VM/LXC lifecycle)
and one on each storage used (for disk images and OS templates).

Pool ACLs propagate to VM and LXC objects in the pool, but **not** to storage unless
the storage resource itself is a pool member. The explicit storage ACL ensures template
downloads and disk allocations succeed.

```bash
# Create token with privilege separation enabled
# privsep=1 means the token cannot exceed the user's own privileges
pveum user token add terraform@pve claude-sandbox \
  --comment "Claude Code sandbox token — restricted to /pool/sandbox and storage" \
  --privsep 1

# Grant TerraformSandbox on the sandbox pool
# Covers all VM/LXC lifecycle operations for resources in this pool
pveum acl modify /pool/sandbox \
  --roles TerraformSandbox \
  --tokens terraform@pve!claude-sandbox

# Grant TerraformSandbox on the storage used for VM disks and LXC templates
# Replace <datastore-id> with your actual storage name (e.g. local-lvm, local, ceph-pool)
pveum acl modify /storage/<datastore-id> \
  --roles TerraformSandbox \
  --tokens terraform@pve!claude-sandbox

# If templates are stored on a separate datastore (common for local vs local-lvm splits):
# pveum acl modify /storage/<template-datastore-id> \
#   --roles TerraformSandbox \
#   --tokens terraform@pve!claude-sandbox
```

Copy the token value from the output and add it to `.envrc`:
```bash
export PROXMOX_VE_API_TOKEN="terraform@pve!claude-sandbox=<uuid-from-output>"
```

### What this token can and cannot do

| Operation | Allowed |
|---|---|
| Create/delete VMs and LXC containers in sandbox pool | Yes |
| Clone VM templates (source template must be readable) | Yes |
| Configure CPU, memory, disk, network, cloud-init | Yes |
| Start/stop VMs and containers | Yes |
| Take and roll back snapshots | Yes |
| Download LXC OS templates to storage | Yes |
| Create or modify Linux bridges | **No** — requires `Sys.Modify` |
| Create/delete pools or move resources between pools | **No** — requires `Pool.Allocate` |
| Modify Proxmox users, roles, or ACLs | **No** — requires `Permissions.Modify` |
| Read or write resources outside `/pool/sandbox` | **No** — API returns 403 |

### Verification

```bash
# Should work — token has Pool.Audit on /pool/sandbox
pvesh get /pools/sandbox --output-format json

# Should fail with 403 — correct behavior
pvesh get /nodes

# Should fail with 403 — correct behavior
pvesh get /cluster/resources
```

---

## Step 6 — Operator's Token: operator-production

```bash
pveum user token add terraform@pve operator-production \
  --comment "Operator production token — full cluster management" \
  --privsep 1

# Grant TerraformOperator at root — covers all paths including nodes and storage
pveum acl modify / \
  --roles TerraformOperator \
  --tokens terraform@pve!operator-production
```

**Store this token in your password manager.** It must NEVER be placed in:
- The `.envrc` file in this repository
- The dev container environment
- Any file committed to git

---

## Template Access for VM Cloning

When cloning a VM template, Proxmox checks `VM.Clone` on the **source** template
in addition to `VM.Allocate` on the destination pool. If the template lives outside
`/pool/sandbox`, you must grant read access explicitly:

```bash
# Grant VM.Clone on the source template VM (replace <template-vmid>)
pveum acl modify /vms/<template-vmid> \
  --roles TerraformSandbox \
  --tokens terraform@pve!claude-sandbox
```

Alternatively, place the template in the sandbox pool so the existing pool ACL covers it.

---

## Verification Commands

```bash
# List all ACLs for the terraform user
pveum acl list | grep terraform

# Show token details and privilege separation flag
pveum user token list terraform@pve

# List role definitions
pveum role list
pveum role permissions TerraformSandbox
pveum role permissions TerraformOperator

# Confirm sandbox token cannot read nodes (expect 403)
pvesh get /nodes --ticket "terraform@pve!claude-sandbox=<token>"
```
