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

## Config Structure

```yaml
environment: <env>
domain_name: "..."
ssh: { public_key, default_user }

infrastructure:
  proxmox: { ip, port, node, insecure }
  network:  { bridge, vlan_id, cidr }
  storage:  { datastore_id, cloudinit_datastore_id }

terraform: { pool_id, vm_id_range_start, clone_template_id, state_bucket }

services:
  minio:  { ip, port, ansible_user, hostname }
  pki:
    root_ca:   { ip, gateway, vm_id, ansible_user, hostname, cloud_init_template_id }
    issuing_ca: { ip, gateway, ct_id, ansible_user, hostname, lxc_template_file_id }

hosts:
  <group>:    # ad-hoc VMs not covered by a named service
    <hostname>: { ansible_host, ansible_user }
```

## Generated Files

| Generated file | Source in config YAML |
|---|---|
| `terraform/<env>.tfvars` | `infrastructure.proxmox`, `infrastructure.network`, `infrastructure.storage`, `terraform`, `ssh`, `services.pki` |
| `ansible/inventory/hosts.yml` | `services` (auto-derived groups) + `hosts` (manual/ad-hoc groups) |
| `.devcontainer/squid/allowed-cidrs.conf` | `infrastructure.network.cidr`, `services.minio.ip`, `infrastructure.proxmox.ip` |
| `.envrc` (non-secret portion) | `infrastructure.proxmox.ip/port/insecure`, `services.minio.ip/port` |
| `.env.mk` | `terraform.state_bucket`, `environment` |

After editing `config/<env>.yml`, always run:
```
make configure            # sandbox
make configure ENV=production
```

## Derivations performed by the generator

- `infrastructure.proxmox.ip` + `port` → `https://{ip}:{port}` for envrc, `{ip}/32` for Squid
- `services.minio.ip` + `port` → `http://{ip}:{port}` for envrc (when tls:false), `{ip}/32` for Squid, bare IP for ansible_host
- `services.minio.fqdn` + `tls` → `https://{fqdn}:{port}` for envrc (when tls:true); also emitted as `minio_domain` in `hosts.yml` minio group vars
- `services.minio.tls` → `minio_tls_enabled` group var in `hosts.yml`
- `domain_name` → `minio_ca_url: https://ca.{domain_name}` group var in `hosts.yml` minio group
- `services.*` with `ip` → Ansible inventory group auto-derived (no manual `hosts:` entry needed)
- `services.pki.*` sub-hosts → `pki_root_ca` / `pki_issuing_ca` Ansible groups

## Secret Boundaries

| Value | Where it lives | NEVER in |
|---|---|---|
| Proxmox API token | `.envrc` (manual) | config YAML |
| MinIO access key | `.envrc` (manual) | config YAML |
| MinIO secret key | `.envrc` (manual) | config YAML |
| MinIO root password | `.envrc` as `MINIO_ROOT_PASSWORD` (Ansible reads via `lookup('env', ...)`) | config YAML or role defaults |
| MinIO root user | `.envrc` as `MINIO_ROOT_USER` (Ansible reads via `lookup('env', ...)`) | config YAML or role defaults |
| SSH public key | `config/<env>.yml` | `.tf` files |
| All other infra config | `config/<env>.yml` | hardcoded in `.tf` or playbooks |

## Constraints

- NEVER put API tokens, passwords, or keys in `config/<env>.yml`
- NEVER edit `terraform/<env>.tfvars`, `ansible/inventory/hosts.yml`, or `.devcontainer/squid/allowed-cidrs.conf` directly
- `infrastructure.network.cidr` MUST use CIDR notation (`/24`, `/32`) — never a bare IP
- Service IPs (`services.*.ip`) use bare IPs for flat services; CIDR notation for PKI sub-hosts (Terraform needs the prefix for cloud-init static IPs)
- `config/<env>.yml` is gitignored. Only `*.yml.example` files are committed.

## Adding a new service

1. Add a `services.<name>:` entry with `ip`, `port` (if applicable), `ansible_user`, `hostname`
2. Run `make configure` — the generator auto-derives the Ansible inventory group and Squid CIDR
3. No edits to `hosts:` needed unless the service has non-standard inventory requirements

## Devcontainer Exception

`make configure` may regenerate `.devcontainer/squid/allowed-cidrs.conf` as a downstream output.
This is the **only** permitted modification under `.devcontainer/`.
The Squid proxy does NOT pick up the change at runtime — the operator must run `make build` and reopen the container for it to take effect.
