---
name: tf-troubleshoot
description: Structured diagnostics for failed Terraform operations in the Proxmox homelab. Covers auth errors, state lock, partial apply, backend failures, and cloud-init issues.
model: opus
---

# Skill: Terraform Troubleshooting

## When to Activate

- `terraform plan` or `terraform apply` fails with an error
- Terraform state appears corrupted or out of sync
- MinIO backend is unreachable or returns errors
- VM/LXC created but not reachable (no IP, SSH timeout)
- Proxmox API returns 403, 500, or timeout errors
- `terraform validate` passes but plan/apply fails

## Critical Rule

**Do NOT attempt state manipulation commands** (`terraform state rm`, `terraform state mv`, `terraform import`, `terraform force-unlock`). These are blocked by the terraform-guard hook and require explicit operator approval. Diagnose with read-only commands first, then escalate to the operator with findings.

## Diagnostic Procedures

### 403 Forbidden on API Calls

**Symptoms:** `Error: 403 Forbidden`, `status: 403`, or `insufficient permissions` in plan/apply output.

**Diagnostic commands:**
```bash
# Check which token is configured
echo $PROXMOX_VE_API_TOKEN

# Verify token format (should be user@realm!token-name=secret)
# Sandbox token: terraform@pve!claude-sandbox
# Production token: terraform@pve!operator-production

# Test API connectivity
curl -sk -H "Authorization: PVEAPIToken=$PROXMOX_VE_API_TOKEN" \
  "$PROXMOX_VE_ENDPOINT/api2/json/pools" 2>&1 | head -20
```

**Root causes:**
| Cause | Evidence | Resolution |
|---|---|---|
| Wrong token loaded | Token name doesn't match expected | Check `.envrc`, run `direnv allow` |
| Token expired or revoked | API returns 401, not 403 | Operator must recreate token in Proxmox |
| Resource outside sandbox pool | 403 on specific resource, not all | Move resource to sandbox pool (operator) or change module `pool_id` |
| Missing privilege for operation | 403 on specific action (e.g., snapshot) | Check `docs/proxmox-iam.md` for TerraformSandbox role privileges |

**Escalate to operator if:** Token is correct but 403 persists on sandbox-pool resources.

---

### State Lock Stuck (MinIO)

**Symptoms:** `Error acquiring the state lock`, `Lock Info:`, `ConditionalCheckFailedException` or long hang at "Acquiring state lock..."

**Diagnostic commands:**
```bash
# Check if another terraform process is running
ps aux | grep terraform

# Check MinIO connectivity
curl -s "$MINIO_ENDPOINT/minio/health/live"

# List lock objects in the state bucket (read-only)
aws --endpoint-url "$MINIO_ENDPOINT" s3 ls "s3://tfstate-sandbox/" --recursive 2>&1
```

**Root causes:**
| Cause | Evidence | Resolution |
|---|---|---|
| Previous apply crashed mid-run | Lock info shows old timestamp | Operator runs `terraform force-unlock <ID>` |
| Concurrent apply in progress | Lock info shows recent timestamp, PID exists | Wait for the other apply to finish |
| MinIO unavailable | Connection refused or timeout | Check MinIO LXC status in Proxmox UI |

**Important:** MinIO does NOT support DynamoDB state locking. The lock is advisory — concurrent applies can corrupt state. Always verify no other apply is running before asking the operator to force-unlock.

**Escalate to operator:** Always. State lock operations require `terraform force-unlock` which is blocked by the hook.

---

### Backend Connection Failure (MinIO Unreachable)

**Symptoms:** `Error configuring S3 Backend`, `RequestError: send request failed`, `dial tcp ... connect: connection refused`, or `no such host`.

**Diagnostic commands:**
```bash
# Test MinIO endpoint connectivity
curl -sv "$MINIO_ENDPOINT/minio/health/live" 2>&1

# Check if proxy is configured (should route through Squid)
echo "http_proxy=$http_proxy"
echo "MINIO_ENDPOINT=$MINIO_ENDPOINT"

# Test S3 API through proxy
aws --endpoint-url "$MINIO_ENDPOINT" s3 ls 2>&1 | head -5

# Check if terraform has been initialized
ls -la terraform/.terraform/
```

**Root causes:**
| Cause | Evidence | Resolution |
|---|---|---|
| MinIO LXC is down | `connection refused` | Operator starts MinIO LXC in Proxmox |
| Squid proxy blocking MinIO IP | `403 Forbidden` from Squid | Check `allowed-cidrs.conf` includes MinIO IP, operator rebuilds container |
| Wrong endpoint in `.envrc` | Endpoint doesn't match MinIO IP | Fix `MINIO_ENDPOINT` in `.envrc`, run `direnv allow` |
| Credentials wrong | `InvalidAccessKeyId` or `SignatureDoesNotMatch` | Fix `MINIO_ACCESS_KEY`/`MINIO_SECRET_KEY` in `.envrc` |
| Init never ran | No `.terraform/` directory | Run `make init` |

---

### Partial Apply (Tainted Resources)

**Symptoms:** Apply completed with errors, some resources created and others failed. `terraform plan` shows `(tainted)` resources or unexpected changes.

**Diagnostic commands:**
```bash
# Check current state
cd terraform && terraform state list

# Show specific resource state
terraform state show 'module.<name>.proxmox_virtual_environment_vm.this'

# Re-run plan to see what terraform wants to do now
terraform plan -var-file=sandbox.tfvars -out=sandbox.tfplan
```

**Root causes:**
| Cause | Evidence | Resolution |
|---|---|---|
| Transient API failure during apply | Some resources created, one error mid-apply | Re-run `terraform plan` then `terraform apply` with the new plan |
| Tainted resource | Plan shows `replaced` for a resource | Review if replacement is acceptable, then re-apply |
| Cloud-init timeout during creation | VM created but marked tainted | Check VM in Proxmox UI — if running fine, ask operator to `terraform untaint` |
| Disk/network conflict | Provider error about already-in-use resource | Check Proxmox UI for conflicting VMID or IP |

**Key principle:** `terraform plan` after a partial apply will show what remains to be done. Review the plan carefully — it may want to destroy and recreate tainted resources.

---

### Cloud-Init: VM Created but No IP

**Symptoms:** VM appears in Proxmox UI but `terraform output -json` shows empty IP arrays. SSH connections fail.

**Diagnostic commands:**
```bash
# Check terraform output
cd terraform && terraform output -json | python3 -m json.tool

# Check Proxmox UI (read-only API call)
curl -sk -H "Authorization: PVEAPIToken=$PROXMOX_VE_API_TOKEN" \
  "$PROXMOX_VE_ENDPOINT/api2/json/nodes/<node>/qemu/<vmid>/agent/network-get-interfaces" 2>&1
```

**Root causes:**
| Cause | Evidence | Resolution |
|---|---|---|
| qemu-guest-agent not installed in template | API returns `QEMU guest agent is not running` | Install agent in template, rebuild |
| `agent.enabled = false` in module | Check module config | Set `agent { enabled = true }` |
| VM hasn't finished booting | Recent create, empty IPs | Wait 60s, re-read output with `terraform refresh` |
| Cloud-init config wrong | VM running but no network | Check `initialization.ip_config` in module — DHCP needs working DHCP server on VLAN |
| VLAN mismatch | VM on wrong network segment | Check `vlan_id` matches sandbox VLAN |

---

### Terraform Validate Passes but Plan Fails

**Symptoms:** `terraform validate` returns "Success!" but `terraform plan` produces errors.

**Diagnostic commands:**
```bash
cd terraform

# Check which var-file is being used
ls -la *.tfvars

# Validate var-file contents (look for missing required variables)
terraform plan -var-file=sandbox.tfvars 2>&1 | head -30

# Check provider version
terraform version
terraform providers
```

**Root causes:**
| Cause | Evidence | Resolution |
|---|---|---|
| Missing variable in tfvars | `No value for required variable` | Add variable to `config/sandbox.yml`, run `make configure` |
| Provider version mismatch | `Unsupported attribute` or `unexpected block type` | Check `versions.tf` pins, run `terraform init -upgrade` |
| Backend not initialized | `Backend initialization required` | Run `make init` |
| Stale lock file | `.terraform.lock.hcl` conflicts | Delete lock file, re-init (ask operator) |

## General Escalation Checklist

When diagnosing any failure, collect this information before escalating to the operator:

1. **Exact error message** (full text, not summary)
2. **Command that failed** (with all flags)
3. **Environment** (`echo $PROXMOX_VE_ENDPOINT`, sandbox vs production)
4. **State list** (`terraform state list` output)
5. **Recent changes** (what was the last successful apply, what changed since)

Present findings as: "Here's what I diagnosed, here's what I believe the root cause is, here's what needs operator-level access to fix."
