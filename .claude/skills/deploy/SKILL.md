---
name: deploy
description: Full PGE pipeline for sandbox deployments. Orchestrates infra-plan → generate → review → terraform plan → terraform apply with human checkpoints at each step.
disable-model-invocation: true
---

# Skill: Deploy Pipeline

Orchestrate the full Planner-Generator-Evaluator (PGE) pipeline for sandbox deployments.

## Pipeline Sequence

### Step 1: Plan

Follow the `infra-plan` skill with the user's request.

**Checkpoint:** Stop and wait for explicit user approval of the plan before proceeding. Accept revisions and re-plan if requested.

### Step 2: Generate

Follow the `generate` skill with the approved plan from Step 1.

Continues automatically when `terraform validate` passes. If validation fails, surface the errors and stop.

### Step 3: Review

Follow the `review` skill on all files modified in Step 2.

**Checkpoint:**
- BLOCK — present blocking issues, stop. Do not proceed until fixed and re-reviewed.
- WARN — present warnings and ask the user whether to proceed.
- APPROVE — continue.

### Step 4: Pre-flight (Ansible deployments with CLI tools only)

**Skip this step for Terraform-only changes.**

Before running any Ansible playbook that calls CLI tools (step-ca, consul, vault, etc.) for the **first time**, verify every non-trivial flag used in tasks actually exists in the installed binary version on the target host:

```bash
ansible <host> -m command -a "<tool> <subcommand> --help" 2>&1 | grep "<flag>"
```

Check each flag that is:
- Not a universal flag (`--help`, `--version`)
- Version-gated (release notes mention it) or tool-specific (not in man page training data)

**If a flag is missing:** fix the task before running, not after the first failure.

**Why this matters:** Static review (Step 3) cannot catch version-specific CLI behavior. A 30-second `--help` grep prevents fix-and-retry cycles that otherwise only surface at runtime.

### Step 5: Terraform Plan

```bash
make plan
# equivalent to: terraform plan -var-file=sandbox.tfvars -out=sandbox.tfplan
```

**Checkpoint:** Present the plan diff output. Explicitly ask the user to confirm before applying. Watch for unexpected `destroy` or `replace` operations — flag them clearly.

### Step 6: Terraform Apply

```bash
make apply
# equivalent to: terraform apply sandbox.tfplan
```

Report the full apply output. If apply fails, surface the error — do not retry automatically.

## Post-Apply

Retrieve VM/LXC IPs:
```bash
cd terraform && terraform output -json
```

Add IPs to `config/sandbox.yml` under `hosts.sandbox.<hostname>.ansible_host`, then:
```bash
make configure        # regenerates inventory and allowed-cidrs
make ansible-sandbox  # optional post-provision playbooks
```

## Verification Checklist

- [ ] VM/LXC appears in Proxmox UI under the sandbox pool
- [ ] VM is reachable via SSH through Squid CONNECT: `ncat --proxy squid-proxy:3128 --proxy-type http <VM_IP> 22`
- [ ] Ansible can reach the VM: `ansible sandbox -m ping`
- [ ] Terraform state is consistent: `terraform state list`
- [ ] No resources outside `/pool/sandbox` were created

## Rolling Back

Plan and apply the destroy:
```bash
terraform plan -var-file=sandbox.tfvars -out=rollback.tfplan
# review the destroy operations
terraform apply rollback.tfplan
```

Or destroy a specific module:
```bash
terraform destroy -var-file=sandbox.tfvars -target=module.vm_name
```

## Constraints

- Sandbox only — production applies are blocked by the terraform-guard hook
- Never skip any checkpoint — each gate exists because the cost of a bad apply exceeds the cost of pausing
