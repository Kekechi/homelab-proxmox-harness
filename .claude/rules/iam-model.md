---
paths:
  - "terraform/**/*.tf"
  - "terraform/**/*.tfvars*"
  - ".envrc*"
  - "docs/proxmox-iam.md"
  - "scripts/bootstrap-minio.sh"
---

# IAM Model

## Proxmox Identities

| | Claude's token | Operator's token |
|---|---|---|
| **Token ID** | `terraform@pve!claude-sandbox` | `terraform@pve!operator-production` |
| **ACL path** | `/pool/sandbox` only | `/` (full cluster) |
| **Role** | `TerraformSandbox` | `TerraformOperator` |
| **privsep** | `1` — cannot exceed user privileges | `1` |
| **In dev container** | Yes (env var `PROXMOX_VE_API_TOKEN`) | No |

Claude's token physically cannot touch resources outside `/pool/sandbox`. Even if the network restriction were bypassed, the Proxmox API returns 403 for out-of-pool resources.

## TerraformSandbox Role Privileges

Allowed: `Datastore.AllocateSpace`, `Datastore.AllocateTemplate`, `Datastore.Audit`, `Pool.Audit`, `SDN.Use`, `VM.Allocate`, `VM.Audit`, `VM.Clone`, `VM.Config.*`, `VM.Console`, `VM.Migrate`, `VM.Monitor`, `VM.PowerMgmt`, `VM.Snapshot`, `VM.Snapshot.Rollback`

Excluded: `Sys.Modify`, `Sys.Audit`, `Sys.PowerMgmt`, `Permissions.Modify`, `User.Modify`, `Pool.Allocate`

Network bridge creation (`proxmox_virtual_environment_network_linux_bridge`) requires `Sys.Modify` at `/nodes/<node>`, which is intentionally excluded. Bridges must be created by the operator token.

## MinIO Identities

Each environment has its own MinIO instance. The dev container is configured for one
environment at a time (Squid allowlist is built from a single `config/<env>.yml`).

| | Claude's key (sandbox) | Operator's key |
|---|---|---|
| **MinIO instance** | Sandbox MinIO only | Per-environment MinIO |
| **Bucket access** | `tfstate-sandbox` only | `tfstate-<env>` on that instance |
| **Operations** | GetObject, PutObject, ListBucket | Full admin |
| **In dev container** | Yes (`MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY`) | No |

The scoped IAM key is created by `scripts/bootstrap-minio.sh <env>` — one key per
environment, bound to a policy that allows access to `tfstate-<env>` only. Claude's key
physically cannot reach the production MinIO instance (different VNet, not in Squid allowlist).

To switch the dev container to a different environment: `make configure ENV=<env>` +
`make build` + reopen container.
