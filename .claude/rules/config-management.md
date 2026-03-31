---
paths:
  - "config/**"
  - "terraform/*.tfvars*"
  - "ansible/inventory/**"
  - ".envrc*"
  - "scripts/generate-configs.py"
  - ".devcontainer/squid/allowed-cidrs.conf"
---

# Configuration Management

## Single Source of Truth

`config/<env>.yml` is the authoritative source for all non-secret environment configuration.
NEVER edit generated files directly — they are overwritten on the next `make configure` run.

## Generated Files

| Generated file | Source in config YAML |
|---|---|
| `terraform/<env>.tfvars` | `proxmox`, `network`, `storage`, `terraform`, `ssh` sections |
| `ansible/inventory/hosts.yml` | `hosts` section |
| `.devcontainer/squid/allowed-cidrs.conf` | `network.cidr`, `minio.host_cidr`, `proxmox.host_cidr` |
| `.envrc` (non-secret portion) | `proxmox.endpoint`, `proxmox.insecure`, `minio.endpoint` |
| `.env.mk` | `terraform.state_bucket`, `environment` |

After editing `config/<env>.yml`, always run:
```
make configure            # sandbox
make configure ENV=production
```

## Secret Boundaries

| Value | Where it lives | NEVER in |
|---|---|---|
| Proxmox API token | `.envrc` (manual) | config YAML |
| MinIO access key | `.envrc` (manual) | config YAML |
| MinIO secret key | `.envrc` (manual) | config YAML |
| MinIO root password | ansible vault (`group_vars/all/vault.yml`) | config YAML or role defaults |
| MinIO root user | ansible vault | config YAML or role defaults |
| SSH public key | `config/<env>.yml` | `.tf` files |
| All other infra config | `config/<env>.yml` | hardcoded in `.tf` or playbooks |

## Constraints

- NEVER put API tokens, passwords, or keys in `config/<env>.yml`
- NEVER edit `terraform/<env>.tfvars`, `ansible/inventory/hosts.yml`, or `.devcontainer/squid/allowed-cidrs.conf` directly
- CIDR fields (`network.cidr`, `minio.host_cidr`, `proxmox.host_cidr`) MUST use CIDR notation with prefix length (`/24`, `/32`) — never bare IPs
- `config/<env>.yml` is gitignored. Only `*.yml.example` files are committed.

## Devcontainer Exception

`make configure` may regenerate `.devcontainer/squid/allowed-cidrs.conf` as a downstream output.
This is the **only** permitted modification under `.devcontainer/`.
The Squid proxy does NOT pick up the change at runtime — the operator must run `make build` and reopen the container for it to take effect.
