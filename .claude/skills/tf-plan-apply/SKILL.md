---
name: tf-plan-apply
description: Terraform init, plan, and apply workflow for this homelab. Covers backend initialization, var-file usage, plan-file gate, and state locking caveats.
---

# Skill: Terraform Plan/Apply Workflow

## When to Activate

- Running `terraform init`, `plan`, or `apply`
- Switching between sandbox and production state backends
- Troubleshooting backend connection failures
- Explaining the two-step plan → apply workflow

## Backend Initialization

The S3 backend bucket is not hardcoded — pass it at init time. Credentials come from env vars set by direnv.

**Sandbox:**
```bash
cd terraform
terraform init \
  -backend-config="bucket=tfstate-sandbox" \
  -backend-config="access_key=$MINIO_ACCESS_KEY" \
  -backend-config="secret_key=$MINIO_SECRET_KEY" \
  -backend-config="endpoints={s3=\"$MINIO_ENDPOINT\"}"
```

**Production (plan only — operator applies):**
```bash
cd terraform
terraform init \
  -backend-config="bucket=tfstate-production" \
  -backend-config="access_key=$MINIO_ACCESS_KEY" \
  -backend-config="secret_key=$MINIO_SECRET_KEY" \
  -backend-config="endpoints={s3=\"$MINIO_ENDPOINT\"}" \
  -reconfigure
```

Use `-reconfigure` when switching from sandbox to production backend (or vice versa) — it discards the cached backend config without migrating state.

Or simply: `make init` (sandbox) / `make plan-prod` (production reinits automatically).

## Plan Workflow (Sandbox)

```bash
cd terraform

# 1. Validate syntax
terraform validate

# 2. Lint
tflint --recursive

# 3. Plan — always use -out and -var-file
terraform plan -var-file=sandbox.tfvars -out=sandbox.tfplan

# 4. Review the plan output before applying
# 5. Apply the saved plan
terraform apply sandbox.tfplan
```

**Never** `terraform apply` without a plan file. **Never** `terraform apply -auto-approve`.

## Plan Naming Conventions

| Environment | Plan file | Var file |
|---|---|---|
| Sandbox | `sandbox.tfplan` | `sandbox.tfvars` |
| Production | `production.tfplan` | `production.tfvars` |

Plan files are gitignored. They are single-use — re-run plan if the configuration changes.

## State Locking Caveat

MinIO does not support DynamoDB-compatible state locking. If two applies run concurrently against the same bucket, state corruption is possible. Mitigations:

1. Claude Code always uses the plan-file workflow (shorter apply window)
2. Coordinate with the operator before applying — confirm no concurrent work

If state becomes corrupt: `terraform state pull > backup.tfstate`, then restore from MinIO versioned object.

## Var-File Setup

Copy the example file and fill in real values:
```bash
cp terraform/sandbox.tfvars.example terraform/sandbox.tfvars
# Edit sandbox.tfvars with your node, pool, datastore, bridge, VLAN, CIDR
```

`*.tfvars` is gitignored. Never commit it.

## GitLab Backend Migration

When ready to migrate from MinIO to GitLab:
1. `terraform state pull > backup.tfstate`
2. Replace `backend "s3"` block in `terraform/backend.tf` with `backend "http"` block
3. `terraform init -migrate-state`
4. Verify: `terraform state list`
