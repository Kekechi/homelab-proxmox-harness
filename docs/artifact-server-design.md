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
- Extend `proxmox-lxc` module with optional second disk (`data_disk_size` string variable default null, `data_disk_path` string variable default `"/mnt/data"`); `dynamic "mount_point"` conditioned on `data_disk_size != null` with: `volume = var.datastore_id` (datastore name only — provider allocates the disk), `size = var.data_disk_size`, `path = var.data_disk_path`; `mount_options` omitted (Nexus tmpdir requires exec). Note: `volume` and `size` are separate provider arguments — do not combine them as `"datastore:size"`.
- Migrate `lxc_template_file_id` from `services.pki.issuing_ca` to `infrastructure.storage` in generator and example configs; emit globally before service blocks (not inside PKI block); remove from PKI block
- Add Nexus block to `gen_tfvars()` emitting `nexus_ct_id`, `nexus_ipv4_address`, `nexus_ipv4_gateway`, `nexus_bridge`; `gen_inventory()` handles Nexus automatically via the generic flat-service loop (no change needed)
- Add `NEXUS_ADMIN_PASSWORD` to `gen_envrc()` and `_ENVRC_SECRET_VARS` in `generate-configs.py`
- Add `nexus_ct_id` (default 205), `nexus_ipv4_address` (null), `nexus_ipv4_gateway` (null), `nexus_bridge` (no default — generator always emits it; Terraform will error at plan time if missing from tfvars) to `variables.tf`. Note: the `proxmox-lxc` module's internal `bridge` variable has a default of `"vmbr0"` but all callers pass it explicitly — the root variable having no default is the correct enforcement point.
- Add `module "nexus"` call to `main.tf`: cores=2, memory_mb=8192, disk_size_gb=8, data_disk_size="20G", data_disk_path="/mnt/nexus-data", os_type="debian"
- Update `sandbox.yml.example` (nexus ct_id=205) and `production.yml.example` (nexus ct_id=105); `lxc_template_file_id` moves to `infrastructure.storage` in both

**IP notation rule (Terraform-provisioned vs externally-managed):**
Nexus uses CIDR notation in config (`ip: "X.X.X.X/24"`). The rule is: Terraform-provisioned LXCs/VMs use CIDR (provider needs the prefix for cloud-init static IP assignment); externally-managed services (e.g. minio) use bare IP. This applies to all flat services that are provisioned by Terraform.

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
> Deploy Nexus Repository CE LXC per `docs/artifact-server-design.md`. Sandbox first.
>
> **Phase 1 — Terraform scope:**
> (1) Extend `proxmox-lxc` module: add `data_disk_size` (string, null) and `data_disk_path`
>     (string, "/mnt/data") variables; add `dynamic "mount_point"` conditioned on
>     `data_disk_size != null`; `volume = var.datastore_id`, `mount_options` empty.
> (2) Migrate `lxc_template_file_id` from `services.pki.issuing_ca` to
>     `infrastructure.storage` in generator; emit globally before PKI/DNS blocks;
>     remove from PKI block; update both example configs.
> (3) Generator: add Nexus block to `gen_tfvars()` emitting `nexus_ct_id`,
>     `nexus_ipv4_address`, `nexus_ipv4_gateway`, `nexus_bridge`; add
>     `NEXUS_ADMIN_PASSWORD` to `gen_envrc()` and `_ENVRC_SECRET_VARS`.
>     (`gen_inventory()` handles Nexus automatically — no change needed.)
> (4) Add `nexus_ct_id` (default 205), `nexus_ipv4_address` (null),
>     `nexus_ipv4_gateway` (null), `nexus_bridge` (required) to `variables.tf`.
> (5) Add `module "nexus"` to `main.tf`: 2 cores, 8192 MB RAM, 8 GB OS disk,
>     20 GB data disk at `/mnt/nexus-data`, os_type=debian.
> (6) Update `sandbox.yml.example` (nexus ct_id=205) and
>     `production.yml.example` (nexus ct_id=105).
>
> **Phase 2 — Ansible scope (separate session):**
> Nexus CE tarball install, JVM config via nexus.vmoptions, systemd unit,
> nginx reverse proxy, step-ca TLS cert (step_client role dependency),
> APT proxy repos, OCI registry, Terraform registry, admin credential bootstrap.
> Firewall egress rule is manual (operator-configured).
