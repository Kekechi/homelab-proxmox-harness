# infra-plan

Plan an infrastructure change for the Proxmox homelab sandbox. Uses the iac-planner agent (Opus) to produce a structured plan before any code is written.

> **Note:** This skill is named `infra-plan` (not `plan`) to avoid conflicting with Claude Code's built-in `/plan` command for plan mode.

## Usage

```
/infra-plan <description of what you want to deploy or change>
```

**Examples:**
- `/infra-plan deploy a Ubuntu 24.04 VM with 2 cores and 4GB RAM in the sandbox VLAN`
- `/infra-plan create an LXC for running a small nginx reverse proxy`
- `/infra-plan add a Linux bridge on vmbr1 for a second VLAN`

## Output

The plan includes:
- **Resources table** — what will be created/modified/destroyed and at what risk
- **Variables Required** — what values you need to supply in `sandbox.tfvars`
- **Dependency Order** — what must be provisioned in what sequence
- **Risk Assessment** — destructive actions, rollback plan, sandbox scope confirmation
- **Implementation Notes** — provider-specific quirks

## After the Plan

Review the plan. Say "approved" (or similar) to proceed.

- To write code immediately: say "approved" then use `/generate`
- To run the full pipeline: use `/deploy` instead (plan → generate → review → apply in one flow)

## Constraints

- Plans are always sandbox-scoped (`/pool/sandbox`)
- Production changes are noted as "Operator applies manually"
- iac-planner flags any privileges not in the `TerraformSandbox` role
