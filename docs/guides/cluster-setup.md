# Cluster Setup Guide

Operator prerequisites for expanding the Proxmox datacenter to a multi-node cluster.
This guide covers the platform layer — the steps that must be completed before
running `make configure` and `terraform apply` against a cluster config.

## 1. Cluster Formation

Form the cluster on the node that will become `pve1`, then join the remaining nodes.
Refer to the [Proxmox VE Cluster Manager documentation](https://pve.proxmox.com/wiki/Cluster_Manager)
for the authoritative procedure.

Rename nodes to `pve1`, `pve2`, `pve3` as part of cluster formation. After renaming,
existing Terraform state will drift (see [State Migration](#state-migration) below).

## 2. NFS Shared Storage

An NFS server is needed to provide cluster-wide access to LXC templates and the VM
template disk (ID 9000). Without shared storage, templates must be uploaded separately
to each node.

### 2a. NFS Server

Deploy an NFS server on one of the Proxmox nodes (operator choice — typically the most
stable node). The NFS server exports a single directory used for template storage.
This node is a provisioning SPOF — if it is unavailable, new deployments cannot pull
templates, but existing workloads continue running.

NFS server setup is a manual operator step (requires Proxmox host shell access, outside
IaC project scope).

### 2b. Proxmox Datacenter Storage

Add `nfs-shared` as a datacenter-level storage entry in the Proxmox web UI:

- **Storage ID:** `nfs-shared`
- **Type:** NFS
- **Server:** NFS server IP
- **Export:** NFS export path
- **Content:** `VZDump backup file`, `Container template`, `ISO image`
  (at minimum: `Container template`)
- **Nodes:** All nodes

The storage ID `nfs-shared` is the value expected by `lxc_template_file_id` in the
cluster config (`infrastructure.storage.lxc_template_file_id`).

### 2c. Storage ACLs

The IaC service account (`terraform-sandbox` or `terraform-production`) needs:

- `Datastore.AllocateSpace` on `/storage/nfs-shared`
- `Datastore.Audit` on `/storage/nfs-shared`

Add these in the Proxmox Datacenter → Permissions → Storage Permissions view.
See `docs/proxmox-iam.md` for the full IAM model.

## 3. Template Upload

### LXC Template

```bash
pveam download nfs-shared debian-13-standard_13.0-1_amd64.tar.zst
```

Run on any cluster node. The template is stored on `nfs-shared` and accessible
cluster-wide.

### VM Template (ID 9000)

```bash
STORAGE=nfs-shared bash scripts/setup-vm-template.sh
```

Run on any cluster node. The VM template disk lands on `nfs-shared` so any node
can clone from it. The script defaults to `nfs-shared` — no override needed for
cluster setups.

## 4. Pool and IAM Setup

Pool and token setup is unchanged. See `docs/proxmox-iam.md`.

Ensure the service account has the required permissions on `nfs-shared` storage
(see [Storage ACLs](#2c-storage-acls) above).

## 5. Config Migration (existing `sandbox.yml`)

If you have an existing `config/sandbox.yml` from a single-node setup:

1. **Remove** `infrastructure.proxmox.node`
2. **Add** `infrastructure.nodes` map:
   ```yaml
   infrastructure:
     nodes:
       pve1:
         ip: "YOUR_PVE1_IP"
   ```
3. **Add** `node: pve1` (or the appropriate node name) to every service block:
   `minio`, `pki.root_ca`, `pki.issuing_ca`, `dns.auth`, `dns.dist`, `nexus`
4. **Update** `infrastructure.storage.lxc_template_file_id` to:
   `"nfs-shared:vztmpl/debian-13-standard_13.0-1_amd64.tar.zst"`
5. Run `make configure` — the generator will validate the new schema and emit
   updated tfvars and allowed-cidrs.

If any field is missing, the generator will exit with a descriptive error message.

## 6. State Migration

When the Proxmox node is renamed from `pve` to `pve1` (as part of cluster formation),
existing Terraform state records `node_name = "pve"` for all resources. The next
`terraform plan` will show `node_name` drift on every resource.

**Provider behavior:**
- **LXC containers** (`proxmox_virtual_environment_container`): `node_name` is
  `ForceNew` — the provider will plan a destroy+recreate for any container with
  stale `node_name`.
- **VMs** (`proxmox_virtual_environment_vm`): `node_name` is not `ForceNew`, but
  the `migrate` argument defaults to `false`, which also means destroy+recreate.

**Recommended procedure (avoids destruction):**

> **Note:** `terraform state rm` and `terraform import` are operator-executed commands.
> Claude Code does not run state manipulation commands without explicit operator approval.

For each resource showing `node_name` drift, use state manipulation to reconcile
the recorded node name without touching the resource:

```bash
# Example for the issuing CA LXC (repeat for each drifted resource)
terraform state rm module.issuing_ca.proxmox_virtual_environment_container.this
terraform import module.issuing_ca.proxmox_virtual_environment_container.this pve1/lxc/201
```

Replace `pve1` with the new node name and `201` with the actual container/VM ID.
Check `terraform show` or the Proxmox UI for the current IDs before running.

After reconciliation, `terraform plan` should show zero resource changes (only
`node_name` metadata updated in state).

## 7. Ongoing Node Migration

### LXC Containers (GUI-first — recommended)

1. Migrate the container in the Proxmox web UI (or via `pct migrate`)
2. Update `node:` in `config/<env>.yml` to match the new node
3. Run `make configure`
4. Run `terraform plan` — confirm zero resource changes

Changing `node:` in config without migrating first will cause `terraform apply` to
destroy and recreate the container (ForceNew).

### VMs

1. Change `node:` in `config/<env>.yml`
2. Run `make configure`
3. Run `terraform plan` — plan will show destroy+recreate (since `migrate = false`)
4. Acceptable for stateless VMs (e.g., `root-ca` which is started only for cert signing)

## 8. Single-Node Compatibility

A single-node config with one entry in `infrastructure.nodes` and all services
pointing to it works identically to the pre-cluster setup. No special handling required.
The same config schema and code path serves both single-node and multi-node deployments.
