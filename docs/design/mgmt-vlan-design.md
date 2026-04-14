# Design: Management VLAN — Multi-Network Config Support

## Goal

Production infrastructure spans multiple Proxmox SDN VNets (management, LAN, DMZ, and
future segments). The current config model assumes one network per environment, which
is sufficient for sandbox but breaks for production. This design extends the config
schema, generator, and Terraform plumbing to support named networks with per-service
placement, while keeping sandbox operation unchanged.

## Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Cross-VLAN access model | Single-homed services; firewall controls access | Dual-homing bypasses the isolation boundary being built. the network firewall enforces VLAN boundaries, not topology. |
| Config model | Named network map (`infrastructure.networks`) | Per-service bridge override (Option A) underestimates blast radius — a bridge change implies subnet, gateway, IP range, and Squid CIDR changes. Named networks centralize the full definition. |
| `vlan_id` in network definition | Optional field, defaults `null` | Proxmox SDN VNets handle VLAN tagging transparently. Kept as optional escape hatch for future edge cases. |
| `ip` field location | Stays on service | Easier to track per-service, and IP is assigned service by service, not at network definition time. |
| `gateway` field location | Moves from service to network definition | Gateway is a property of the network, not the service. Removes repeated copy-paste per service and eliminates wrong-gateway errors on services that move networks. |
| `default_network` | Optional field in config | Sandbox sets it (single network, zero noise). Production omits it (forces explicit `network:` on every service — absence is self-documenting intent). Generator errors at `make configure` time if a service has no `network:` and no `default_network` is set. |
| Generator migration | Hard cut — single schema, no backward compat | One operator, two config files. Dual-schema detection adds generator complexity for zero benefit. Both example files updated in the same commit as the generator rewrite. |
| Sandbox topology | Single network, no second VNet | Sandbox tests service behavior and Ansible playbooks. VLAN boundary enforcement is inherently production-only (requires the network firewall rules). Accepted divergence, documented explicitly. |

## Schema

### Network definition (per named network)

```yaml
infrastructure:
  networks:
    mgmt:
      bridge: mgmt            # Proxmox VNet bridge name
      cidr: "X.X.X.X/24"     # Used for Squid allowlist and group vars
      gateway: "X.X.X.1"     # Injected into Terraform ipv4_gateway per service
      vlan_id: null           # Optional; null = VNet handles it (always null in current setup)
    lan:
      bridge: lan
      cidr: "X.X.X.X/24"
      gateway: "X.X.X.1"
      vlan_id: null
  default_network: mgmt       # Optional — omit in production to force explicit placement
```

### Service placement

```yaml
services:
  dns:
    auth:
      network: mgmt           # explicit — or omitted if default_network covers it
      ip: "X.X.X.X/24"
      # gateway resolved from networks.mgmt — no longer on service
    dist:
      network: mgmt
      ip: "X.X.X.X/24"
  kubernetes:
    network: lan              # explicit override — different from default
    ip: "X.X.X.X/24"
```

### Sandbox example (single network, convenience default)

```yaml
infrastructure:
  networks:
    sandbox:
      bridge: sandbox
      cidr: "X.X.X.X/24"
      gateway: "X.X.X.1"
      vlan_id: null
  default_network: sandbox    # all services inherit — no network: field needed
```

## Generator Changes

| Output file | Change |
|---|---|
| `terraform/<env>.tfvars` | Per-service `<service>_bridge` vars emitted, resolved from `networks[service.network].bridge`. Global `bridge`, `vlan_id`, and `network_cidr` vars removed. `*_ipv4_gateway` vars continue to be emitted but sourced from `networks[service.network].gateway` instead of `service.gateway`. |
| `ansible/inventory/hosts.yml` | `pdns_dnsdist_acl_cidrs` base CIDR resolved from `networks[dns_dist.network].cidr` (the network dns-dist is assigned to), not the global `infrastructure.network.cidr`. The `client_cidrs` override list is appended as now — required when dns-dist serves clients on a different network (e.g. LAN clients querying a dns-dist on mgmt). |
| `.devcontainer/squid/allowed-cidrs.conf` | One CIDR entry per named network that has at least one deployed service. `proxmox_ip/32` continues as a special case derived from `infrastructure.proxmox.ip`. MinIO `/32` entry is dropped — covered by its network's CIDR being in the list. |

### `network:` field applies to both flat and nested services

```yaml
services:
  minio:                  # flat service
    network: mgmt
    ip: "X.X.X.X"
    port: 9000
    # gateway resolved from networks.mgmt — not on service
  dns:                    # nested service
    auth:
      network: mgmt
      ip: "X.X.X.X/24"
    dist:
      network: mgmt
      ip: "X.X.X.X/24"
```

The generator resolves `bridge` and `gateway` from the named network for both flat and
nested service code paths.

## Terraform Changes

| Layer | Change |
|---|---|
| `variables.tf` | Global `bridge`, `vlan_id`, and `network_cidr` vars removed. Per-service `<service>_bridge` vars added for each deployed service (e.g. `dns_auth_bridge`, `issuing_ca_bridge`). Per-service `*_ipv4_gateway` vars already exist — their values now derive from the named network definition in the generator, not from `service.gateway` in the YAML. |
| `main.tf` | Each module call uses `var.<service>_bridge` instead of `var.bridge`. `vlan_id` hardcoded to `null` in all module calls — Proxmox SDN VNets always handle tagging transparently. |
| Modules (`proxmox-lxc`, `proxmox-vm`) | No changes needed — `bridge` and `vlan_id` inputs already exist. |

### Gateway source change (all affected services)

All four `*_ipv4_gateway` variables exist in `variables.tf` today. Their source in the
generator changes from `service.gateway` (on the service dict) to
`networks[service.network].gateway` (on the named network definition). The Terraform
variable names and module wiring are unchanged.

| Variable | Current source | New source |
|---|---|---|
| `root_ca_ipv4_gateway` | `services.pki.root_ca.gateway` | `networks[root_ca.network].gateway` |
| `issuing_ca_ipv4_gateway` | `services.pki.issuing_ca.gateway` | `networks[issuing_ca.network].gateway` |
| `dns_auth_ipv4_gateway` | `services.dns.auth.gateway` | `networks[dns.auth.network].gateway` |
| `dns_dist_ipv4_gateway` | `services.dns.dist.gateway` | `networks[dns.dist.network].gateway` |

## Component Summary

| Service | Production network | Sandbox network | Always-on |
|---|---|---|---|
| Root CA (VM) | mgmt | sandbox | No (offline) |
| Issuing CA (LXC) | mgmt | sandbox | Yes |
| DNS Auth+Recursor (LXC) | mgmt | sandbox | Yes |
| DNSdist (LXC) | mgmt | sandbox | Yes |
| MinIO (LXC) | mgmt (planned migration) | sandbox | Yes |
| Kubernetes (future) | lan | sandbox | TBD |
| Vaultwarden (future) | lan | sandbox | Yes |
| File share (future) | lan | sandbox | TBD |
| Greenbone/Wazuh (future) | mgmt | sandbox | TBD |

## Sandbox Testing Scope

Sandbox uses a single VNet bridge. Services that will be on separate VNets in production
are co-located in sandbox. This means:

- **Testable in sandbox:** Terraform provisioning, Ansible playbooks, service-to-service
  communication (DNS resolution, PKI cert issuance, etc.)
- **Not testable in sandbox:** the network firewall inter-VLAN firewall rules, DHCP scope behavior
  per VLAN, enforcement of network isolation boundaries

Inter-VLAN firewall rule testing is production-only. Validate firewall rules manually
after production deployment before enabling services for LAN clients.

## Open Items (deferred, not forgotten)

- **Production service placement confirmation** — actual VNet bridge names and IPs for
  MGMT subnet TBD. Required before `/infra-plan` for production deployment.
- **MinIO migration to MGMT** — currently on sandbox VLAN. Migration path (new LXC on
  MGMT, state bucket migration) is a separate planning session.
- **the network firewall firewall rules** — MGMT ingress/egress policy, LAN→MGMT on service ports.
  Out of IaC scope; operator-configured. Required before production services go live.
- **Squid container rebuild** — after `make configure` adds new network CIDRs to
  `allowed-cidrs.conf`, operator must run `make build` and reopen the dev container.

## Ready for Planning

This design is complete. Hand to `/infra-plan` with:

> Implement Management VLAN multi-network support per `docs/design/mgmt-vlan-design.md`.
> Changes span: `scripts/generate-configs.py`, `config/sandbox.yml.example`,
> `config/production.yml.example`, `terraform/variables.tf`, `terraform/main.tf`,
> `.claude/rules/config-management.md`.
> No module changes needed. Sandbox apply permitted after plan review.
