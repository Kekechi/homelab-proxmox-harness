---
paths:
  - "config/**"
  - "terraform/*.tfvars*"
  - "ansible/inventory/**"
  - ".envrc*"
  - "scripts/generate-configs.py"
  - "scripts/genconfig/**"
  - "components/*/component.yml"
  - "components/*/config.example.yml.in"
---

# Configuration Management

## Single Source of Truth

`config/<env>.yml` is the authoritative source for all non-secret environment
configuration. `config/<env>.local.yml` (gitignored) deep-merges over it for private
components and machine-specific values. NEVER edit generated files directly — they carry
DO-NOT-EDIT headers and are overwritten on the next `make configure`.

## Who owns the schema

Component manifests do. Each `components/<name>/component.yml` (and
`components.local/<name>/`) declares its instances and their config keys —
`required` / `optional` / `defaults` — plus capability contracts
(`consumes` / `provides`). The generator (`scripts/generate-configs.py` →
`scripts/genconfig/`) discovers components, validates `config/<env>.yml` against the
manifests, resolves capabilities, and emits every downstream artifact. Central files
never encode per-service knowledge; to see what keys a service accepts, read its
manifest or the assembled `config/<env>.yml.example`.

## Config structure (top level)

```yaml
environment: <env>
domain_name: "..."
ssh:   { public_key, default_user }
agent: { ssh_private_key, ssh_extra_args? }   # controller-host facts → generated ansible.cfg

infrastructure:
  dns_server: "..."               # resolv.conf pushed to instances via Terraform
  proxmox: { ip, port, insecure }
  nodes: { <name>: { ip } }       # one entry per cluster node
  networks:
    <name>: { bridge, cidr, gateway, vlan_id }   # cidr MUST be CIDR notation
  default_network: <name>         # optional; omit in production to force explicit placement
  storage: { datastore_id, cloudinit_datastore_id, lxc_template_file_id }

terraform: { pool_id, vm_id_range_start, clone_template_id, state_bucket }

services:
  <instance_key>: { node, ip, ... }   # keys defined by the owning component's manifest

hosts:
  <group>: { <hostname>: { ansible_host, ansible_user } }   # ad-hoc, non-component hosts
```

## Generated files

| Generated file | Emitter (`scripts/genconfig/emit/`) | Notes |
|---|---|---|
| `terraform/<env>.tfvars` | `tfvars.py` | typed `services` map for the two `for_each` blocks + shared vars |
| `ansible/inventory/hosts.yml` | `inventory.py` | enabled components (auto-derived groups) + `hosts:` + capability-derived group vars |
| `ansible/ansible.cfg` | `ansible_cfg.py` | from the `agent:` section (key path, extra ssh args) |
| `.envrc` (non-secret portion) | `envrc.py` | smart-merge preserves secret lines; sources `.envrc.local` (never templated) |
| `.env.mk` | `env_mk.py` | `ENV`, state bucket for the Makefile |
| `ansible/inventory/group_vars/pki_*` | `pki_group_vars.py` | PKI sub-host vars |
| `config/*.yml.example` | `config_example.py` | assembled from `config/example-core/<env>.yml.in` + `components/*/config.example.yml.in` (via `make examples`) |

After editing `config/<env>.yml` or a manifest: `make configure` (add `ENV=production`
for prod). After editing example fragments: `make examples`. Generator output is
byte-stable for unchanged input — `scripts/test-golden.py` is the oracle; run it after
any generator change.

## Capability contracts

Cross-component values flow through `consumes` / `provides` declared in manifests —
never name-based reaches inside emitters. When a provider component's value changes,
re-converge reporting from `make configure` lists which consumers need their playbooks
re-run.

## Secret Boundaries

| Value | Where it lives | NEVER in |
|---|---|---|
| Proxmox API token | `.envrc` (manual) | config YAML |
| MinIO access/secret key | `.envrc` (manual) | config YAML |
| MinIO root user/password | `.envrc` (Ansible reads via `lookup('env', ...)`) | config YAML or role defaults |
| Component service secrets (API keys etc.) | `.envrc`, declared by the manifest's `env:` section | config YAML or role defaults |
| Machine-specific extras | `.envrc.local` (gitignored, never templated) | git |
| SSH public key | `config/<env>.yml` | `.tf` files |
| All other infra config | `config/<env>.yml` (+ `.local.yml` overlay) | hardcoded in `.tf` or playbooks |

The placeholder sentinel for unset secrets is `CHANGE_ME` (declared per manifest) — the
generator and secret tooling agree on it; never invent a different sentinel.

## Constraints

- NEVER put API tokens, passwords, or keys in `config/<env>.yml`
- NEVER edit generated files (see table above) — regenerate instead
- `infrastructure.networks.<name>.cidr` MUST use CIDR notation, never a bare IP
- Service IPs use bare IPs for flat services; CIDR notation where the manifest requires
  a prefix for cloud-init static addressing (e.g. PKI sub-hosts)
- A service's `network:` (and `default_network`) must reference a key in `infrastructure.networks`
- `gateway:` belongs to `infrastructure.networks.<name>`, never to a service
- `config/<env>.yml` and `config/<env>.local.yml` are gitignored; only `*.yml.example` is committed
- Name/tf_key collision between `components/` and `components.local/` is a hard error

## Adding a new service

Create `components/<name>/` (manifest + config fragment + playbook + verify.sh), add its
`services.<key>:` block to `config/<env>.yml`, run `make configure` — no central-file
edits. Full checklist: `components/CLAUDE.md`. For a new field on an existing service:
add it to the manifest and fragment, read it in the relevant emitter if it must be
emitted, then update the golden baselines (`scripts/test-golden.py --update`, review the
diff).
