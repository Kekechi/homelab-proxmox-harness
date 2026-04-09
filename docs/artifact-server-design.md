# Design: Internal Artifact Server (Nexus CE)

## Goal

A self-hosted repository manager on the management segment that
eliminates direct internet dependency for managed hosts. All MGMT
hosts pull packages from this server. LAN hosts and workstations
onboard later via client-side config. The artifact server and the
Proxmox host are the only MGMT hosts with controlled internet egress.

## Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Software | Sonatype Nexus Repository CE (v3.89+) | Only free tool covering APT + OCI + Terraform natively; Ansible Galaxy omitted |
| Internet access model | Artifact server gets explicit firewall egress to specific upstream domains; all other MGMT hosts have no internet | Single controlled exit point; Proxmox host gets own rule post-MGMT-migration |
| Generic HTTP (ISOs, LXC templates) | Phase 1: Proxmox keeps direct internet egress (own firewall rule). Phase 2: evaluate Nexus Raw proxy per pveam configurability | Not a MGMT air-gap blocker; Proxmox is last to migrate to MGMT |
| Cross-VLAN consumer access | Single-homed on MGMT; firewall rule LAN→artifact-server:8443 | Consistent with established MGMT access model |
| Consumer rollout | MGMT hosts first; LAN/workstations via client-side config when ready | Low blast radius; no network changes required to onboard new consumers |
| Break-glass | Regular LXC snapshots (primary); temporary firewall rule for direct internet if disk lost | Snapshot covers majority of failures without internet |
| LXC vs VM | LXC | JVM does not require hardware virtualization; LXC reduces overhead on RAM-constrained host |
| LXC sizing | 8 GB RAM, 8 GB OS disk, 20 GB data disk (separate) | 8 GB is documented minimum (official small profile); JVM heap floor is 2703m alone |
| Database | Embedded H2 (CE default) | Supported for low-concurrency homelab use; PostgreSQL not required |
| TLS termination | nginx reverse proxy on same LXC (port 8443 → localhost:8081) | Official recommendation: offload TLS from JVM; simpler cert management with PEM vs Java keystore |
| TLS cert | step-ca issuing CA | Consistent with all other always-on MGMT services |
| Ansible Galaxy | Explicitly omitted | Single-maintainer community plugin; arbitrary code execution risk not justified |

## JVM Configuration

Per official documentation (`nexus.vmoptions`):

```
-Xms2703m
-Xmx2703m
-XX:MaxDirectMemorySize=2g
-Dkaraf.data=/path/to/data-disk
-Djava.io.tmpdir=/path/to/data-disk/tmp
```

- 2703m is the documented minimum heap floor; chosen over the recommended 4g to preserve OS headroom on an 8 GB LXC
- Data directory set via `-Dkaraf.data` (not a `NEXUS_DATA` env var — that is not an official mechanism)
- Data disk mount must not use `noexec` — Nexus tmpdir requires exec permissions

## Component Summary

| Component | Type | Network (prod) | Network (sandbox) | Always-on |
|---|---|---|---|---|
| Nexus CE LXC (Nexus + nginx) | LXC | MGMT | Sandbox VLAN | Yes |

## Artifact Types — Day 1 Scope

| Format | Protocol | Status |
|---|---|---|
| APT packages | Debian repo | Native in Nexus CE |
| OCI/container images | Container registry | Native in Nexus CE |
| Terraform providers | Terraform registry | Native in Nexus CE (v3.89+); v3.88 had Pro-only auth, v3.89 fixed for CE |
| LXC templates / ISOs | Generic HTTP | Phase 2 — Nexus Raw proxy (evaluate pveam configurability) |
| Ansible Galaxy | Galaxy protocol | Explicitly out of scope |

## Prerequisites

**Before `/infra-plan`:**
- Add `help.sonatype.com` to `squid.conf` `allowed_domains` (Nexus documentation)
- Add port `8081` to `squid.conf` `Safe_ports` (Ansible API calls to Nexus during role execution)
- Run `make build` and reopen dev container

**Implementation prerequisites (planner must include):**
- Extend `proxmox-lxc` module with optional second disk (`mount_point` block, size/datastore/path variables)
- Add Nexus section to `gen_tfvars()` and `gen_inventory()` in `generate-configs.py`
- Add `NEXUS_ADMIN_PASSWORD` to `gen_envrc()` and `_ENVRC_SECRET_VARS` in `generate-configs.py`

**Before production deployment:**
- MGMT VLAN multi-network config (`docs/mgmt-vlan-design.md`) must be implemented

## Open Items (deferred, not forgotten)

- **pveam configurability** — verify whether LXC template download source URL is overridable; determines Phase 2 effort for generic HTTP
- **Firewall egress domain list** — derived from which upstream repos are enabled in Nexus; finalized during Ansible configuration
- **Consumer onboarding** — apt source config per host is incremental; no fixed timeline

## Deploy Phases

| Phase | Work | Prerequisite |
|---|---|---|
| 1 | Sandbox: Terraform LXC + Ansible Nexus + nginx config + firewall egress rule | Squid updated, container rebuilt |
| 2 | Production: same, on MGMT VNet | MGMT VLAN config implemented |
| 3 | Consumer onboarding (client-side APT/TLS config per host) | Phase 1 or 2 stable |

## Ready for Planning

Run `/infra-plan` with:
> Deploy Nexus Repository CE LXC per `docs/artifact-server-design.md`.
> Single LXC, 8 GB RAM, 8 GB OS disk, 20 GB separate data disk.
> TLS via nginx reverse proxy on same LXC (port 8443 → localhost:8081);
> cert from step-ca issuing CA.
> Sandbox first. Scope includes:
> (1) extending `proxmox-lxc` module with optional second disk,
> (2) adding Nexus section to generator (`gen_tfvars`, `gen_inventory`, `gen_envrc`),
> (3) Terraform LXC provisioning,
> (4) Ansible role: install Nexus CE tarball, configure JVM via nexus.vmoptions,
>     systemd unit, nginx reverse proxy, step-ca TLS cert (step_client role
>     dependency), APT proxy repos, OCI registry, Terraform registry,
>     initial admin credential bootstrap.
> Firewall egress rule is manual (operator-configured).
