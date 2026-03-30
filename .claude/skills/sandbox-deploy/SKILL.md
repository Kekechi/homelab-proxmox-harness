---
name: sandbox-deploy
description: End-to-end workflow for deploying a new VM or LXC to the sandbox using the Planner-Generator-Evaluator pipeline. Covers the full sequence from request to running VM.
---

# Skill: Sandbox Deployment Workflow

## When to Activate

- Deploying a new VM or LXC to sandbox
- Running the `/deploy` command
- Explaining the PGE (Planner-Generator-Evaluator) pipeline
- Troubleshooting a failed sandbox deployment

## The PGE Pipeline

Three agents collaborate in sequence:

```
User request
    │
    ▼
[iac-planner]  (Opus)     → Structured plan document
    │                        Waits for user approval
    ▼ (approved)
[iac-generator] (Sonnet)  → Terraform/Ansible code
    │
    ▼
[tf-reviewer]  (Sonnet)   → Review report (APPROVE/WARN/BLOCK)
    │
    ▼ (APPROVE or WARN)
terraform plan -var-file=sandbox.tfvars -out=sandbox.tfplan
    │
    ▼ (user reviews plan output)
terraform apply sandbox.tfplan
    │
    ▼
[Ansible post-provision]  (optional)
```

## Step-by-Step Workflow

### 1. Plan (iac-planner agent)

Provide a description of what you want deployed. The iac-planner will:
- Read existing modules to find reusable building blocks
- Research bpg/proxmox provider docs if needed
- Produce a structured plan: resources, variables, dependencies, risk

**Wait for user approval before proceeding.**

### 2. Generate (iac-generator agent)

With the approved plan, iac-generator will:
- Add module calls to `terraform/main.tf`
- Add variables to `terraform/variables.tf`
- Create new modules if needed
- Run `terraform validate` and report results

### 3. Review (tf-reviewer agent)

tf-reviewer checks the generated code against the full review checklist:
- Security (credentials, pool scope, sensitive vars)
- bpg/proxmox correctness (resource names, CPU, disk, network)
- Module quality (reusability, outputs)

If BLOCK: fix issues and re-review before proceeding.
If WARN: fix high-severity issues, proceed with caution.
If APPROVE: continue to plan step.

### 4. Terraform Plan

```bash
cd terraform
terraform validate
tflint --recursive
terraform plan -var-file=sandbox.tfvars -out=sandbox.tfplan
```

Review the plan output. Confirm no unexpected destroy operations.

### 5. Terraform Apply

**User reviews plan output and approves.**

```bash
cd terraform
terraform apply sandbox.tfplan
```

### 6. Post-Provision (Ansible, optional)

After apply, retrieve VM IPs from outputs:
```bash
cd terraform && terraform output -json
```

Update `ansible/inventory/sandbox/hosts.yml` with actual IPs, then run playbooks:
```bash
make ansible-sandbox
```

## Verification Checklist

After deployment:
- [ ] VM/LXC appears in Proxmox UI under the sandbox pool
- [ ] VM is reachable via SSH through Squid CONNECT (test with `ncat --proxy squid-proxy:3128 --proxy-type http <VM_IP> 22`)
- [ ] Ansible can reach the VM (`ansible sandbox -m ping`)
- [ ] Terraform state is consistent (`terraform state list`)
- [ ] No resources outside `/pool/sandbox` were created

## Rolling Back

If something goes wrong after apply:
1. `terraform plan -var-file=sandbox.tfvars -out=rollback.tfplan` (will show destroy)
2. Review the destroy plan
3. `terraform apply rollback.tfplan`

Or destroy specific resources:
```bash
terraform destroy -var-file=sandbox.tfvars -target=module.vm_name
```
