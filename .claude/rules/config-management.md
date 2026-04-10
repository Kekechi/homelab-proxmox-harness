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
  proxmox: { ip, port, insecure }
  nodes: { <name>: { ip } }  # one entry per cluster node
  networks:
    <name>:         # named network; one per Proxmox VNet
      bridge: ...   # VNet bridge name
      cidr: ...     # CIDR notation; used for Squid allowlist and group vars
      gateway: ...  # injected as ipv4_gateway per service
      vlan_id: null # optional; null when SDN VNets handle tagging
  default_network: <name>  # optional; omit in production to force explicit placement
  storage:  { datastore_id, cloudinit_datastore_id }

terraform: { pool_id, vm_id_range_start, clone_template_id, state_bucket }

services:
  minio:  { node, ip, port, ansible_user, hostname, network }
  pki:
    root_ca:   { node, ip, vm_id, ansible_user, hostname, cloud_init_template_id, network }
    issuing_ca: { node, ip, ct_id, ansible_user, hostname, network }
  dns:
    auth: { node, ip, ct_id, ansible_user, hostname, network, dns_name? }
    dist: { node, ip, ct_id, ansible_user, hostname, network, dns_name?, dns_ttl?, dns?, client_cidrs? }
  nexus: { node, ip, ct_id, ansible_user, hostname, fqdn, network }

hosts:
  <group>:    # ad-hoc VMs not covered by a named service
    <hostname>: { ansible_host, ansible_user }
```

## Generated Files

| Generated file | Source in config YAML |
|---|---|
| `terraform/<env>.tfvars` | `infrastructure.nodes + per-service node:` → `*_node (root_ca_node, issuing_ca_node, dns_auth_node, dns_dist_node, nexus_node)`; `infrastructure.proxmox`, `infrastructure.networks` (per-service bridge/gateway resolved via service's `network:` reference), `infrastructure.storage`, `terraform`, `ssh`, `services.pki` |
| `ansible/inventory/hosts.yml` | `services` (auto-derived groups) + `hosts` (manual/ad-hoc groups) |
| `.devcontainer/squid/allowed-cidrs.conf` | one CIDR entry per named network that has at least one deployed service; `infrastructure.proxmox.ip` |
| `.envrc` (non-secret portion) | `infrastructure.proxmox.ip/port/insecure`, `services.minio.ip/port` |
| `.env.mk` | `terraform.state_bucket`, `environment` |

After editing `config/<env>.yml`, always run:
```
make configure            # sandbox
make configure ENV=production
```

## Derivations performed by the generator

- `infrastructure.proxmox.ip` + `port` → `https://{ip}:{port}` for envrc, `{ip}/32` for Squid
- `services.minio.ip` + `port` → `http://{ip}:{port}` for envrc (when tls:false), bare IP for ansible_host
- `services.minio.fqdn` + `tls` → `https://{fqdn}:{port}` for envrc (when tls:true); also emitted as `minio_domain` in `hosts.yml` minio group vars
- `services.minio.tls` → `minio_tls_enabled` group var in `hosts.yml`
- `domain_name` → `minio_ca_url: https://ca.{domain_name}` group var in `hosts.yml` minio group
- `services.*` with `ip` → Ansible inventory group auto-derived (no manual `hosts:` entry needed)
- `services.*` with `dns_name` → overrides the DNS A record label (default: service key, underscores → hyphens)
- `services.*` with `dns_ttl` → overrides TTL for that host's A record (default: 3600)
- `services.*` with `dns: false` → excludes that host from DNS record generation entirely
- `services.pki.*` sub-hosts → `pki_root_ca` / `pki_issuing_ca` Ansible groups
- Per-service `network:` field → looked up in `infrastructure.networks`; `bridge` and `gateway` emitted as `<service>_bridge` and `<service>_ipv4_gateway` in tfvars
- `infrastructure.networks.<name>.cidr` → one entry in `allowed-cidrs.conf` per network that has at least one deployed service

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
- `infrastructure.networks.<name>.cidr` MUST use CIDR notation (`/24`, `/32`) — never a bare IP
- Service IPs (`services.*.ip`) use bare IPs for flat services; CIDR notation for PKI sub-hosts (Terraform needs the prefix for cloud-init static IPs)
- Services with `network:` fields must reference a key in `infrastructure.networks`
- `default_network` (if set) must also reference a key in `infrastructure.networks`
- `gateway:` is NOT a per-service field — it belongs in `infrastructure.networks.<name>.gateway`
- `config/<env>.yml` is gitignored. Only `*.yml.example` files are committed.

## Adding a new service

1. Add a `services.<name>:` entry with `ip`, `port` (if applicable), `ansible_user`, `hostname`, `network`
2. Run `make configure` — the generator auto-derives the Ansible inventory group and Squid CIDR
3. No edits to `hosts:` needed unless the service has non-standard inventory requirements

## Devcontainer Exception

`make configure` may regenerate `.devcontainer/squid/allowed-cidrs.conf` as a downstream output.
This is the **only** permitted modification under `.devcontainer/`.
The Squid proxy does NOT pick up the change at runtime — the operator must run `make build` and reopen the container for it to take effect.
