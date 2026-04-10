# Design: Multi-Node Proxmox Cluster

## Goal

Expand the homelab Proxmox datacenter from a single node to a three-node cluster to
increase available CPU, memory, and storage capacity. Availability is not a goal —
resources are pooled, not replicated. Workload placement is manually controlled per
service. This design also covers the required changes to the IaC project to support
multi-node deployments.

## Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Node count | 3 | Minimum for proper quorum (2-of-3). Avoids QDevice complexity of 2-node setups. |
| Node naming | `pve1` / `pve2` / `pve3` (symmetric) | Existing node renamed on cluster join. Symmetric naming keeps placement decisions flexible. |
| HA / live migration | Not pursued | Goal is capacity, not availability. Heterogeneous laptop hardware makes live migration fragile. |
| Storage model | All-local (`local-lvm`) for VM/LXC disks | Laptops have no shared block storage. Local is correct for high-I/O workloads. |
| Cloud-init storage | Local (`local-lvm`) per node | bpg/proxmox `initialization` block generates the cloud-init drive via API — no snippets, no SSH, no shared storage needed. |
| NFS shared storage | LXC templates + VM template disk only | Templates are read-infrequently; NFS overhead is acceptable. VM template (ID 9000) is cluster-wide unique so it must be on storage accessible to all nodes. LXC templates benefit from single-copy management. |
| NFS server placement | One of the three Proxmox nodes | No dedicated storage device available. Node becomes a provisioning SPOF (not a runtime SPOF — existing workloads keep running). Operator chooses the most stable node. |
| NFS server management | Manual operator prerequisite | NFS setup requires Proxmox host-level and datacenter storage configuration — platform layer, outside IaC project scope. Scripts/docs are appropriate; automation is not. |
| IaC project boundary | Tenant layer only | Project manages what runs on Proxmox (VMs, LXCs, workloads). Proxmox cluster formation, NFS setup, storage config, pool and IAM setup are platform-layer operator responsibilities — consistent with existing prerequisites (VM template, API tokens, pool creation). |
| API endpoint config | `proxmox.ip` kept separate from `nodes.*.ip` | Any cluster node can serve the API (multi-master via pmxcfs). Keeping them separate allows `proxmox.ip` to become a VIP without touching node records, and node IPs to change without affecting the API endpoint. |
| Node assignment model | Per-service `node:` field, mandatory, no default | Manual placement is the stated workflow. Explicit per-service declaration is auditable. No default avoids silent misplacement on heterogeneous hardware. |
| SSH to Proxmox nodes | Not required | Project uses API-only provisioning. No snippet uploads. SSH requirement only applies to snippet-based cloud-init workflows, which this project does not use. |

## Component Summary

### Proxmox Platform (operator-managed, outside project scope)

| Component | Type | Notes |
|---|---|---|
| `pve1` | Proxmox node | Existing node, renamed on cluster join. Designated NFS server host. |
| `pve2` | Proxmox node | New node. |
| `pve3` | Proxmox node | New node. |
| NFS server LXC | Manual prerequisite | Runs on `pve1` (or whichever node operator designates). Exports template storage. |
| `nfs-shared` storage | Proxmox datacenter storage | Defined cluster-wide by operator. NFS mount to NFS server LXC. Content types: `vztmpl`, `iso`. |
| `local-lvm` storage | Per-node | VM/LXC disks and cloud-init drives. Consistent name required across all nodes. |

### IaC Project Layer (this project)

| Component | Node | Always-on |
|---|---|---|
| root-ca (VM) | Configurable via `node:` | No — started only for cert signing |
| issuing-ca (LXC) | Configurable via `node:` | Yes |
| dns-auth (LXC) | Configurable via `node:` | Yes |
| dns-dist (LXC) | Configurable via `node:` | Yes |
| nexus-server (LXC) | Configurable via `node:` | Yes |
| minio-server (LXC) | Configurable via `node:` | Yes |

## Project Code Impact

### Config YAML (`config/*.yml.example`)

- **Remove**: `infrastructure.proxmox.node`
- **Add**: `infrastructure.nodes` map — one entry per node with `ip:` field
- **Add**: `node:` field on every service and sub-service (required, validated against `infrastructure.nodes` keys)
- **Update**: `storage.lxc_template_file_id` value → `nfs-shared:vztmpl/...`
- **Unchanged**: `storage.cloudinit_datastore_id` stays `local-lvm`
- **Breaking**: existing `config/sandbox.yml` requires manual migration before `make configure` works

Example additions to config:

```yaml
infrastructure:
  proxmox:
    ip: "192.168.X.X"   # API endpoint — any node, or a VIP later
    port: 8006
    insecure: true
    # node: removed — per-service now
  nodes:
    pve1:
      ip: "192.168.X.X"   # Squid allowlist entry; all three needed
    pve2:
      ip: "192.168.X.X"
    pve3:
      ip: "192.168.X.X"
  storage:
    datastore_id: local-lvm
    cloudinit_datastore_id: local-lvm        # unchanged — node-local is fine
    lxc_template_file_id: "nfs-shared:vztmpl/debian-13-standard_13.0-1_amd64.tar.zst"

services:
  dns_auth:
    node: pve1     # new required field — references infrastructure.nodes key
    ip: "192.168.X.X/24"
    ...
```

### `scripts/generate-configs.py`

- `validate_schema()`: validate `infrastructure.nodes` is a non-empty map with `ip:` per entry; validate every service `node:` field references a valid key in `infrastructure.nodes`
- `gen_tfvars()`: remove global `proxmox_node` line; emit per-service `<service>_node = "<pveN>"` in each service section
- `gen_allowed_cidrs()`: replace single `proxmox.ip/32` with one `/32` per `infrastructure.nodes.*.ip`, plus `proxmox.ip/32` (deduplicated — covers VIP case where API endpoint differs from node IPs)

### `terraform/variables.tf`

- Remove `variable "proxmox_node"`
- Add one variable per service:

```hcl
variable "root_ca_node"    { description = "Proxmox node for root CA VM";         type = string }
variable "issuing_ca_node" { description = "Proxmox node for issuing CA LXC";     type = string }
variable "dns_auth_node"   { description = "Proxmox node for DNS auth LXC";       type = string }
variable "dns_dist_node"   { description = "Proxmox node for DNSdist LXC";        type = string }
variable "nexus_node"      { description = "Proxmox node for Nexus LXC";          type = string }
```

### `terraform/main.tf`

Each module call changes one argument:

```hcl
# Before
node_name = var.proxmox_node

# After — each module uses its own variable
node_name = var.root_ca_node     # module "root_ca"
node_name = var.issuing_ca_node  # module "issuing_ca"
node_name = var.dns_auth_node    # module "dns_auth"
node_name = var.dns_dist_node    # module "dns_dist"
node_name = var.nexus_node       # module "nexus"
```

### No changes needed

| Layer | Reason |
|---|---|
| `terraform/modules/proxmox-vm/` | Already accepts `node_name` as a plain string — node-agnostic |
| `terraform/modules/proxmox-lxc/` | Same |
| `ansible/` | Targets workload IPs, not Proxmox nodes — entirely unaffected |
| `Makefile` | Unchanged |

### New / updated files

- `docs/cluster-setup.md` — operator guide: cluster formation, NFS LXC setup, Proxmox datacenter storage config, template upload to NFS, pool and IAM setup, config migration guide for existing `sandbox.yml`
- `scripts/setup-vm-template.sh` — update storage target to `nfs-shared` so VM template 9000 is accessible cluster-wide (any node can clone from it)

## Open Items (deferred, not forgotten)

### ~~Verify bpg/proxmox `node_name` ForceNew behavior~~ — Resolved

**Verified against bpg/proxmox v0.99.0 source:**

- **`proxmox_virtual_environment_container` (LXC):** `node_name` has `ForceNew: true`.
  Changing `node_name` in Terraform state destroys and recreates the container.
  No `migrate` argument exists on the container resource.
- **`proxmox_virtual_environment_vm` (VM):** `node_name` does not have `ForceNew`.
  The resource has a `migrate` argument (default `false`). With `migrate = false`,
  changing `node_name` also destroys and recreates the VM.

**Implication:** LXC migrations should always be GUI-first (migrate in Proxmox UI,
update `node:` in config to match). IaC-driven `node:` changes on LXCs are always
destructive. For VMs, destroy+recreate is acceptable for stateless workloads like
`root-ca`. The `migrate` argument is not exposed in the homelab modules
(consistent with the "no live migration" design decision).

See `docs/cluster-setup.md` for detailed migration procedures.

### ~~State migration for existing workloads~~ — Resolved

Documented in `docs/cluster-setup.md` § 6 (State Migration). The recommended procedure
uses `terraform state rm` + `terraform import` per resource to reconcile `node_name`
in state without destroying workloads. These are operator-executed commands.

## Ready for Planning

Hand to `/infra-plan` with the following scope:

1. Config schema changes (`config/sandbox.yml.example`, `config/production.yml.example`)
2. Generator changes (`scripts/generate-configs.py`)
3. Terraform root changes (`terraform/variables.tf`, `terraform/main.tf`)
4. New `docs/cluster-setup.md`
5. Update `scripts/setup-vm-template.sh` guidance for NFS storage target

**Prerequisite before planning**: verify bpg/proxmox `node_name` ForceNew behavior on
`proxmox_virtual_environment_vm` and `proxmox_virtual_environment_container`. Check
provider changelog or source for the `node_name` attribute schema. This affects the
state migration and GUI migration procedures in `cluster-setup.md`.
