---
description: Full Planner-Generator-Evaluator pipeline. Plans, generates code, reviews it, then guides you through terraform plan and apply for sandbox.
allowed_tools: ["Read", "Grep", "Glob", "Bash", "Write", "Edit", "WebSearch", "WebFetch"]
---

# /deploy

Full sandbox deployment pipeline using the Planner-Generator-Evaluator (PGE) architecture.

## What This Command Does

1. **Plan** — iac-planner (Opus) produces a structured plan and waits for your approval
2. **Generate** — iac-generator (Sonnet) writes Terraform code from the approved plan
3. **Evaluate** — tf-reviewer (Sonnet) reviews the generated code for security and correctness
4. **Terraform plan** — runs `terraform plan -var-file=sandbox.tfvars -out=sandbox.tfplan`
5. **Terraform apply** — runs `terraform apply sandbox.tfplan` after your approval of the plan output

**Each step waits for your confirmation before proceeding.**

## Usage

```
/deploy <description of what you want to deploy>
```

**Examples:**
- `/deploy a Ubuntu 24.04 VM with 2 cores, 4GB RAM, static IP 192.168.20.50`
- `/deploy an LXC container running nginx as a reverse proxy`

## Pipeline Details

### Step 1: Plan (requires approval)
- iac-planner reads modules, checks constraints, produces plan document
- You review the plan and say "approved" or request changes

### Step 2: Generate
- iac-generator writes code to `terraform/main.tf`, `terraform/variables.tf`
- Runs `terraform validate` internally — reports results

### Step 3: Review (BLOCK stops here)
- tf-reviewer checks: credentials, pool scope, bpg conventions, module quality
- BLOCK → fix issues, re-review
- WARN → review warnings, decide to proceed
- APPROVE → continue

### Step 4: Terraform Plan (requires approval)
- Runs: `make plan` (`terraform plan -var-file=sandbox.tfvars -out=sandbox.tfplan`)
- You review the plan diff output
- Confirm to proceed

### Step 5: Apply
- Runs: `make apply` (`terraform apply sandbox.tfplan`)
- Reports apply output

## After Deployment

- VM IPs from `terraform output -json`
- Update `ansible/inventory/sandbox/hosts.yml`
- Run `make ansible-sandbox` for post-provision configuration

## Safety

- This command only applies to sandbox — production applies are blocked
- The sandbox-guard validates the apply command before execution
- Any `terraform destroy` in the pipeline requires explicit confirmation
