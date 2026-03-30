# Proxmox IAM Setup

Run these commands on a Proxmox node as root. These are one-time bootstrap steps.

## Identity Model

| Identity | Token | ACL Path | Role | Held By |
|---|---|---|---|---|
| Claude Code | `terraform@pve!claude-sandbox` | `/pool/sandbox` | `TerraformSandbox` | Dev container env var |
| Operator | `terraform@pve!operator-production` | `/` | `TerraformOperator` | Password manager |

---

## Step 1 — Create Proxmox User

Both tokens share a single Proxmox user in the `pve` realm (no shell login).

```bash
pveum user add terraform@pve --comment "Terraform service account"
```

---

## Step 2 — Claude's Role: TerraformSandbox

Minimal privileges for managing VMs and LXC containers within the sandbox pool.
Excludes system-level, permission, and user management operations.

```bash
pveum role add TerraformSandbox \
  --privs "Datastore.AllocateSpace,Datastore.Audit,Pool.Audit,SDN.Use,\
VM.Allocate,VM.Audit,VM.Clone,VM.Config.CDROM,VM.Config.CPU,\
VM.Config.Cloudinit,VM.Config.Disk,VM.Config.HWType,VM.Config.Memory,\
VM.Config.Network,VM.Config.Options,VM.Console,VM.Migrate,\
VM.Monitor,VM.PowerMgmt,VM.Snapshot,VM.Snapshot.Rollback"
```

**Excluded deliberately:** `Sys.Modify`, `Sys.PowerMgmt`, `Permissions.Modify`,
`User.Modify`, `Pool.Allocate`

---

## Step 3 — Operator's Role: TerraformOperator

Full VM and LXC management for production. Includes audit-level system access.

```bash
pveum role add TerraformOperator \
  --privs "Datastore.AllocateSpace,Datastore.Audit,Pool.Allocate,Pool.Audit,\
SDN.Use,Sys.Audit,VM.Allocate,VM.Audit,VM.Clone,VM.Config.CDROM,VM.Config.CPU,\
VM.Config.Cloudinit,VM.Config.Disk,VM.Config.HWType,VM.Config.Memory,\
VM.Config.Network,VM.Config.Options,VM.Console,VM.Migrate,VM.Monitor,\
VM.PowerMgmt,VM.Snapshot,VM.Snapshot.Rollback"
```

---

## Step 4 — Create Sandbox Pool

Resources managed by Claude Code are placed in this pool. The pool must exist before
granting the ACL. Pool membership is managed by the operator — Claude's token does not
have `Pool.Allocate` and cannot add resources to other pools.

```bash
pveum pool add sandbox --comment "Sandbox resources managed by Claude Code / Terraform"
```

---

## Step 5 — Claude's Token: claude-sandbox

```bash
# Create token with privilege separation enabled
# privsep=1 means the token cannot exceed the user's own privileges
pveum user token add terraform@pve claude-sandbox \
  --comment "Claude Code sandbox token — restricted to /pool/sandbox" \
  --privsep 1

# Grant TerraformSandbox role on the sandbox pool ONLY
# Claude cannot read or modify anything outside /pool/sandbox
pveum acl modify /pool/sandbox \
  --roles TerraformSandbox \
  --tokens terraform@pve!claude-sandbox
```

Copy the token value from the output and add it to `.envrc`:
```bash
export PROXMOX_VE_API_TOKEN="terraform@pve!claude-sandbox=<uuid-from-output>"
```

**Verification:** Claude's token should be able to list VMs in the sandbox pool but
NOT list VMs cluster-wide:
```bash
# Should work (scoped to pool)
pvesh get /pools/sandbox

# Should fail with permission denied (correct behavior)
pvesh get /nodes
```

---

## Step 6 — Operator's Token: operator-production

```bash
pveum user token add terraform@pve operator-production \
  --comment "Operator production token — full cluster management" \
  --privsep 1

pveum acl modify / \
  --roles TerraformOperator \
  --tokens terraform@pve!operator-production
```

**Store this token in your password manager.** It must NEVER be placed in:
- The `.envrc` file in this repository
- The dev container environment
- Any file committed to git

---

## Verification Commands

```bash
# List all ACLs
pveum acl list

# Show token details
pveum user token list terraform@pve

# List roles and their privileges
pveum role list
pveum role permissions TerraformSandbox
pveum role permissions TerraformOperator
```
