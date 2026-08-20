---
paths:
  - "terraform/**/*.tf"
  - "terraform/**/*.tfvars*"
  - ".envrc*"
  - "docs/proxmox-iam.md"
  - "components/minio/bootstrap.sh"
---

# IAM Model

## Proxmox Identities

| | Claude's token | Operator's token |
|---|---|---|
| **Token ID** | `terraform@pve!claude-sandbox` | `terraform@pve!operator-production` |
| **ACL path** | `/pool/sandbox` only | `/` (full cluster) |
| **Role** | `TerraformSandbox` | `TerraformOperator` |
| **privsep** | `1` — cannot exceed user privileges | `1` |
| **On the agent host** | Yes (env var `PROXMOX_VE_API_TOKEN`, set in `.envrc`) | No — never |

Claude's token physically cannot touch resources outside `/pool/sandbox`. Even if every
other layer failed, the Proxmox API returns 403 for out-of-pool resources.

## TerraformSandbox Role Privileges

Allowed: `Datastore.AllocateSpace`, `Datastore.AllocateTemplate`, `Datastore.Audit`, `Pool.Audit`, `SDN.Use`, `VM.Allocate`, `VM.Audit`, `VM.Clone`, `VM.Config.*`, `VM.Console`, `VM.Migrate`, `VM.Monitor`, `VM.PowerMgmt`, `VM.Snapshot`, `VM.Snapshot.Rollback`

Excluded: `Sys.Modify`, `Sys.Audit`, `Sys.PowerMgmt`, `Permissions.Modify`, `User.Modify`, `Pool.Allocate`

Network bridge creation (`proxmox_virtual_environment_network_linux_bridge`) requires
`Sys.Modify` at `/nodes/<node>`, which is intentionally excluded. Bridges must be created
by the operator token.

## MinIO Identities

Each environment has its own MinIO instance. The agent host is configured for one
environment at a time (`make configure ENV=<env>` regenerates the endpoints in `.envrc`
and `.env.mk`).

| | Claude's key (sandbox) | Operator's key |
|---|---|---|
| **MinIO instance** | Sandbox MinIO only | Per-environment MinIO |
| **Bucket access** | `tfstate-sandbox` only | `tfstate-<env>` on that instance |
| **Operations** | GetObject, PutObject, ListBucket | Full admin |
| **On the agent host** | Yes (`MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` in `.envrc`) | No |

The scoped IAM key is created by `components/minio/bootstrap.sh <env>` — one key per
environment, bound to a policy that allows access to `tfstate-<env>` only. The production
MinIO instance lives on a network segment the agent host cannot reach; its credentials
never exist on the agent host.
