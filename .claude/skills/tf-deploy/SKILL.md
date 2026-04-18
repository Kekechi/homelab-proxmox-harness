---
name: tf-deploy
description: Full pipeline for Terraform infrastructure deployments. Orchestrates infra-plan → generate → review → terraform plan → terraform apply with human checkpoints at each step.
disable-model-invocation: true
---

# Skill: Terraform Deploy Pipeline

Orchestrate the full Planner-Generator-Evaluator (PGE) pipeline for Terraform infrastructure changes.

## Pipeline Sequence

### Step 1: Plan

Follow the `infra-plan` skill with the user's request.

**Checkpoint:** Stop and wait for explicit user approval of the plan before proceeding. Accept revisions and re-plan if requested.

The `infra-plan` skill will write the approved plan to `.claude/session/plan-<name>.md`.

> **Context reset point:** After the plan is approved and written, say: "Plan written to `.claude/session/plan-<name>.md`. If context is getting long, run `/compact` now — Step 2 reads the plan from that file."

### Step 2: Generate

Follow the `generate` skill with the approved plan from Step 1.

Continues automatically when `terraform validate` passes. If validation fails, surface the errors and stop.

### Step 3: Review

Follow the `polish` skill with `code` on all files modified in Step 2.

The polish skill runs the tf-reviewer subagent, fixes any blocking issues in a fixer subagent, and loops until APPROVE. All fix+re-review cycles stay in subagents — the main session only sees the final verdict.

**After polish resolves:**
- APPROVE — continue.
- WARN — present warnings and ask the user whether to proceed.

> **Context reset point:** After Step 3 APPROVE, say: "Review passed. If context is getting long, run `/compact` now — Steps 4 and 5 are self-contained shell commands."

### Step 4: Terraform Plan

```bash
make plan
# equivalent to: terraform plan -var-file=sandbox.tfvars -out=sandbox.tfplan
```

**Checkpoint:** Present the plan diff output. Explicitly ask the user to confirm before applying. Watch for unexpected `destroy` or `replace` operations — flag them clearly.

### Step 5: Terraform Apply

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
make configure   # regenerates inventory and allowed-cidrs
```

Verify infrastructure:
- [ ] VM/LXC appears in Proxmox UI under the sandbox pool
- [ ] VM is reachable via SSH through Squid CONNECT: `ncat --proxy squid-proxy:3128 --proxy-type http <VM_IP> 22`
- [ ] Ansible can reach the VM: `ansible <host> -m ansible.builtin.ping`
- [ ] Terraform state is consistent: `terraform state list`
- [ ] No resources outside `/pool/sandbox` were created

## Rolling Back

```bash
terraform plan -var-file=sandbox.tfvars -out=rollback.tfplan
# review the destroy operations, then:
terraform apply rollback.tfplan
```

## Constraints

- Sandbox only — production applies are blocked by the terraform-guard hook
- Never skip any checkpoint — each gate exists because the cost of a bad apply exceeds the cost of pausing
