# deploy

Full sandbox deployment pipeline using the Planner-Generator-Evaluator (PGE) architecture. Runs infra-plan → generate → review → terraform plan → terraform apply with a human checkpoint at each step.

## Usage

```
/deploy <description of what you want to deploy>
```

**Examples:**
- `/deploy a Ubuntu 24.04 VM with 2 cores, 4GB RAM, static IP 192.168.20.50`
- `/deploy an LXC container running nginx as a reverse proxy`

## Pipeline

```
User request
    │
    ▼
[iac-planner]  (Opus)     → Structured plan document
    │                        ← you approve here
    ▼
[iac-generator] (Sonnet)  → Terraform/Ansible code
    │
    ▼
[tf-reviewer]  (Sonnet)   → Review report (APPROVE/WARN/BLOCK)
    │                        ← BLOCK stops here
    ▼
terraform plan             → plan diff
    │                        ← you approve here
    ▼
terraform apply            → deployed
    │
    ▼
Ansible post-provision     (optional)
```

Each step waits for your confirmation before proceeding.

## After Deployment

```bash
cd terraform && terraform output -json  # get VM IPs
# add IPs to config/sandbox.yml under hosts.sandbox.<name>.ansible_host
make configure        # regenerate inventory
make ansible-sandbox  # run post-provision playbooks
```

## Safety

- Sandbox only — production applies are blocked by `scripts/hooks/terraform-guard.sh`
- The protected-path-guard hook prevents modifying safety-critical files
- The pre-commit-guard hook prevents committing sensitive files

## Individual Steps

You can also run each phase standalone:
- `/infra-plan <description>` — plan only, wait for approval
- `/generate` — generate code from an approved plan in context
- `/review [path]` — review specific files or the full working tree
