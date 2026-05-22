# homelab-proxmox-harness

Proxmox Private Cloud managed with Terraform and Ansible, with a Claude Code AI-assisted workflow.

## What This Is

Infrastructure-as-Code harness for a self-hosted Proxmox homelab. Terraform provisions VMs and LXCs; Ansible configures them. A Claude Code harness enables AI-assisted planning, code generation, and review via a Planner-Generator-Evaluator (PGE) agent pipeline.

**Key design decisions:**
- Dev container with Squid forward proxy for network isolation — Claude Code cannot reach anything outside the sandbox VLAN
- MinIO (self-hosted S3) for Terraform remote state, with separate sandbox and production buckets
- Centralized config in `config/<env>.yml` — one file generates tfvars, Ansible inventory, Squid allowlist, and `.envrc`
- Production applies are physically blocked — the production API token is not in the dev container

## Architecture

```
┌─────────────────────────────────────────┐
│  Dev Container                          │
│  ┌──────────┐    ┌─────────────────┐   │
│  │ Claude   │    │  Squid Proxy    │   │
│  │ Code     │───▶│  :3128          │   │
│  └──────────┘    └────────┬────────┘   │
│                           │             │
└───────────────────────────┼─────────────┘
                            │ (sandbox VLAN only)
              ┌─────────────┼─────────────┐
              │             │             │
         ┌────▼────┐  ┌────▼────┐  ┌────▼────┐
         │ Proxmox │  │  MinIO  │  │ Sandbox │
         │   API   │  │  :9000  │  │   VMs   │
         └─────────┘  └─────────┘  └─────────┘
```

## Prerequisites

- Proxmox VE cluster (tested on PVE 8.x)
- Docker + Dev Containers (VS Code or compatible)
- [direnv](https://direnv.net/) for `.envrc` management
- MinIO instance running as an LXC on Proxmox (see `docs/guides/minio-setup.md`)
- Proxmox API tokens for sandbox and production (see `docs/proxmox-iam.md`)

## Quick Start

**1. Clone and configure**

```bash
git clone <this-repo>
cd homelab-proxmox-harness

cp config/sandbox.yml.example config/sandbox.yml
# Edit config/sandbox.yml with your Proxmox node, network CIDRs, MinIO IP, etc.

make configure
# Generates: terraform/sandbox.tfvars, ansible/inventory/hosts.yml,
#            .devcontainer/squid/allowed-cidrs.conf, .envrc, .env.mk

# Verify the generated files exist:
ls terraform/sandbox.tfvars ansible/inventory/hosts.yml
```

**2. Fill in secrets**

Edit `.envrc` and replace the three `CHANGE_ME` placeholders:
```bash
# Proxmox API token (from docs/proxmox-iam.md step 3)
export PROXMOX_VE_API_TOKEN="terraform@pve!claude-sandbox=<uuid>"

# MinIO keys (from scripts/bootstrap-minio.sh output)
export MINIO_ACCESS_KEY="terraform-sandbox-<generated>"
export MINIO_SECRET_KEY="<generated>"
```

Then: `direnv allow`

**3. Open the dev container**

After `make configure` updates `allowed-cidrs.conf`, rebuild the dev container:
```bash
make build       # rebuild Squid image with updated allowlist
# Then reopen in dev container:
#   VS Code: Ctrl+Shift+P → "Dev Containers: Reopen in Container"
```

**4. Verify isolation and initialize**

```bash
make verify-isolation    # confirm Squid proxy and network isolation are working
make init                # initialize Terraform with sandbox state bucket
make plan                # terraform plan → sandbox.tfplan
make apply               # terraform apply sandbox.tfplan
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `make configure` fails with "must use CIDR notation" | Bare IP in `infrastructure.network.cidr` or `services.pki.*.ip` | Use CIDR notation (e.g. `192.168.50.0/24`, `192.168.50.10/24`) |
| `make configure` fails with "fqdn is not set" | `services.minio.tls: true` but no `fqdn` | Set `services.minio.fqdn` or change `tls: false` |
| `make init` fails | MinIO not running or `MINIO_ENDPOINT` wrong | Verify MinIO is reachable: `curl -s $MINIO_ENDPOINT/minio/health/live` |
| `make plan` fails with auth error | `PROXMOX_VE_API_TOKEN` not set or expired | Check `.envrc` is loaded: `echo $PROXMOX_VE_API_TOKEN` |
| Template VM not found during apply | `cloud_init_template_id` refers to nonexistent VM | Run `scripts/setup-vm-template.sh` on the Proxmox host first |

## Documentation

| Doc | Contents |
|-----|----------|
| `docs/proxmox-iam.md` | IAM setup — API tokens, roles, ACL paths |
| `docs/guides/minio-setup.md` | MinIO LXC setup and bucket bootstrap |
| `docs/guides/splunk-setup.md` | Splunk Enterprise deployment and OTel Collector wiring |
| `docs/network-policy.md` | Squid proxy allowlist and SSH tunnel architecture |
| `docs/threat-model.md` | What the isolation model protects against (and what it doesn't) |

## Claude Code Harness

This repo includes a structured, **human-in-the-loop** multi-agent orchestration framework built on top of Claude Code. It is not an autonomous agent that blindly runs scripts — every gate requires explicit operator approval before the next stage begins.

### Planner-Generator-Evaluator (PGE) Architecture

Each infrastructure change moves through three distinct, purpose-scoped agent roles:

| Role | Model | Responsibility |
|------|-------|----------------|
| **iac-planner** | Opus | Researches the change, reads existing code, produces a structured plan document — no code written |
| **iac-generator** | Sonnet | Translates the *approved* plan into Terraform/Ansible code — does not plan or review |
| **tf-reviewer** | Sonnet | Reviews generated code for security, correctness, and bpg/proxmox conventions — returns APPROVE / WARN / BLOCK |

The operator approves the plan before any code is generated. The operator reviews the reviewer verdict before any apply runs. No agent can skip a gate or grant itself permission to proceed.

### Security Guardrails

Safety is enforced at three independent layers that do not rely on each other:

- **Squid proxy isolation** — the dev container's outbound traffic is limited to the sandbox VLAN; Claude Code cannot reach the public internet or production infrastructure regardless of what it attempts
- **PreToolUse hooks** — intercept and block dangerous `terraform` subcommands (`destroy`, `state rm`, `force-unlock`) before execution, independent of any instruction Claude receives
- **Credential separation** — the production Proxmox API token is never provisioned inside the dev container; a production apply would fail at authentication even if all other guardrails were bypassed

### Available Skills

| Command | What it does |
|---------|--------------|
| `/design <rough idea>` | Explore and decide on a design — one decision at a time, no code written |
| `/infra-plan <description>` | Plan an infrastructure change using iac-planner (Opus) |
| `/generate` | Write code from an approved plan using iac-generator (Sonnet) |
| `/review [files]` | Review code for security and correctness using tf-reviewer (Sonnet) |
| `/polish [code\|plan\|design]` | Iterative review-fix loop until APPROVE — all fix+re-review cycles stay in subagents |
| `/tf-deploy <description>` | Full Terraform plan → generate → review → apply pipeline |
| `/ansible-deploy <description>` | Full Ansible plan → generate → review → run pipeline |
| `/ansible-run` | Pre-flight + run + verify for already-written Ansible code |
| `/handoff` | Package a production plan with context for operator handoff |
| `/assess <scope>` | Structured project assessment — surfaces hidden assumptions before remediation |
| `/day2-ops` | Resize, snapshot, or reconfigure existing VMs/LXCs |
| `/retro` | Session retrospective — surfaces prompting lessons and workflow insights |

## Environment Switching

```bash
make configure ENV=production     # generate production config files
make init ENV=production          # switch backend to tfstate-production
make plan ENV=production          # plan for production (prints operator warning)
# Production apply is blocked — hand the plan to the operator
```

## Summer 2026 Roadmap (Active Development)

These four engineering priorities are in active design or implementation as of Summer 2026.

1. **Detection Engineering** — Integrating a centralized Splunk logging infrastructure to monitor Proxmox API logs and LXC/VM system events. An OTel Collector Contrib gateway aggregates log streams from all managed hosts and forwards them to Splunk Enterprise via HEC; rsyslog on each LXC requires no reconfiguration when the SIEM backend changes.

2. **Attack Simulation** — Building automated simulation scripts to test infrastructure resilience and validate Splunk detection rules. Simulation exercises target the specific data sources ingested (Proxmox API audit logs, DNS query logs, host auth events) so detection coverage can be verified against known-bad patterns before production incidents occur.

3. **AI-Agent Abuse Defenses** — Hardening the PGE harness against prompt injection and unauthorized tool-use scenarios within the sandbox VLAN. This includes tightening PreToolUse hook coverage, auditing agent tool scope, and documenting adversarial test cases for the threat model.

4. **Splunk Hackathon Submission** — Packaging the logging and detection components for an upcoming infrastructure security hackathon. The submission bundles the OTel Collector → Splunk pipeline, Splunk AI Toolkit / MCP Server integration, and detection rule set as a reproducible reference architecture.

## License

MIT
