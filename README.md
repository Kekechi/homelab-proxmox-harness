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
| `docs/network-policy.md` | Squid proxy allowlist and SSH tunnel architecture |
| `docs/threat-model.md` | What the isolation model protects against (and what it doesn't) |

## Claude Code Harness

This repo includes a Claude Code harness that enables AI-assisted infrastructure work:

| Command | What it does |
|---------|-------------|
| `/plan <description>` | Plans an infrastructure change (no code written) |
| `/generate` | Writes code from an approved plan |
| `/review [files]` | Reviews code for security and correctness |
| `/tf-deploy <description>` | Full Terraform plan → generate → review → apply pipeline |
| `/ansible-deploy <description>` | Full Ansible plan → generate → review → run pipeline |

The harness uses a **Planner-Generator-Evaluator** architecture:
- **iac-planner** (Opus) — researches and designs the change
- **iac-generator** (Sonnet) — writes the Terraform/Ansible code
- **tf-reviewer** (Sonnet) — reviews for security, correctness, and bpg/proxmox conventions

Safety is enforced at multiple layers: path-scoped rules, a PreToolUse hook that blocks dangerous terraform commands, and physical credential isolation.

## Environment Switching

```bash
make configure ENV=production     # generate production config files
make init ENV=production          # switch backend to tfstate-production
make plan ENV=production          # plan for production (prints operator warning)
# Production apply is blocked — hand the plan to the operator
```

## License

MIT
