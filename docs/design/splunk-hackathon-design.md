# Design: Splunk AI Hackathon Infrastructure

## Goal

Deploy Splunk Enterprise as a time-boxed hackathon environment alongside a permanent log
aggregation server. Splunk provides a conversational AI interface for home network security
analysis via the MCP Server and AI Toolkit apps. The log aggregation server (OTel Collector)
is permanent infrastructure that survives Splunk's expiry and feeds future SIEM/observability
backends without source reconfiguration.

---

## Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| IaC isolation | Integrated into existing root module; two separate boolean gates (`enable_log_server`, `enable_splunk`) | Log server is permanent — must survive `enable_splunk: false` teardown; separate gates prevent accidental destruction of permanent infra |
| Network | MGMT VLAN | Consistent with permanent infra placement; all data sources reachable |
| Splunk VM OS | Ubuntu 24.04 LTS | Splunk-supported; stays in Debian family; longest LTS runway |
| Splunk VM cloud-init template | New per-service field `services.splunk.cloud_init_template_id`; emitted as `splunk_cloud_init_template_id` in tfvars | Ubuntu 24.04 template is a second distinct template alongside the existing Debian template; must be a separately named variable to avoid collision with the existing global `cloud_init_template_id` |
| Splunk VM node | Dedicated compute node | Node with sufficient free RAM for Splunk; normally-off reduces contention |
| Splunk VM sizing | Meets Splunk Enterprise minimums (4 vCPU, 12+ GB RAM, 150 GB disk) | Sized for solo hackathon use; sufficient for indexing + search on homelab log volume |
| Splunk VM boot behaviour | `started = true`, `start_on_boot = false` | Must boot on first apply for software install; does not autostart on Proxmox reboot — operator starts it when actively developing |
| Log server — software | OTel Collector Contrib | Emerging enterprise standard; central gateway pattern; CNCF graduated, Apache 2.0; native Splunk HEC sink; retargetable to any future backend via config change |
| Log server — lifecycle | Permanent homelab infrastructure | Sources never need reconfiguration at Splunk expiry; aligns with planned log aggregation layer in homelab roadmap |
| Log server — node | Production node (alongside DNS/Nexus/PKI) | Permanent infra belongs on production node; negligible footprint |
| Log server — sizing | 1 vCPU, 1 GB RAM, LXC, 100 GB disk | OTel Collector at homelab scale; 90-day log retention estimated at ~10–15 GB |
| Log server — OS | Debian 13 (existing LXC template) | No new template required; OTel Collector Contrib has a Debian APT repo |
| Log retention | 90 days raw files on disk | Covers Wazuh/future SIEM onboarding window after Splunk expiry |
| Forwarding model | rsyslog on Linux hosts → OTel Collector → Splunk HEC | No Splunk UF required; rsyslog already present on all LXCs; one forwarding target to change at Splunk expiry |
| Data sources (pre-May 13) | Perimeter firewall syslog, DNSdist query logs, Linux host auth via rsyslog | Covers network + DNS + endpoint layers; sufficient for security demo narrative |
| Data sources (deferred) | Perimeter firewall IDS logs, Nexus application logs | Post-May 13; depends on demo story |
| Splunkbase app delivery | Operator downloads `.tgz` from Splunkbase pre-phase → uploads to Nexus raw repo after Phase 1 step 1 → Ansible fetches from Nexus → Splunk CLI installs | Idempotent; no external dependency during Ansible runs; Nexus raw repo must exist before upload |
| Nexus raw repo mechanism | New `raw_hosted_repos` list in config YAML (under `services.nexus`, parallel to `apt_proxy_repos`) + task loop in `bootstrap.yml` + generator propagation | YAML key is `raw_hosted_repos` (no prefix — already namespaced under `services.nexus`); generator emits it as `nexus_raw_hosted_repos` Ansible group var (prefixed to avoid inventory collisions), parallel to `nexus_apt_proxy_repos` pattern |
| Squid allowlist | Add port 8089 to `Safe_ports` and `SSL_ports` in `squid.conf` | Required for Claude Code → MCP Server (HTTPS on management port); this is a manual edit to `squid.conf` (port entries), distinct from `allowed-cidrs.conf` (IP CIDRs); `make configure` does not handle port entries; operator edit + container rebuild required |
| MCP Server auth | Dedicated Splunk RBAC user with `mcp_tool_execute` capability; created after MCP Server install + Splunk restart | Capability registered by app on install; user creation must follow restart cycle. Token stored in `ansible/inventory/group_vars/all/vault.yml` (existing vault pattern) and manually added to `.envrc` post-provisioning |
| Anthropic API key (`\| ai` command) | Manual addition to `.envrc` post-provisioning | `make configure` does not generate Splunk-specific secrets; `ANTHROPIC_API_KEY` and `SPLUNK_MCP_TOKEN` are operator-added lines in `.envrc` — the generator preserves manually added vars across subsequent `make configure` runs |
| Perimeter firewall IDS | Formally deferred — not a managed host | Separate operational task post-May 13; not IaC-managed |
| Developer License | Pre-phase prerequisite — apply before installing Splunk | Processing takes days; must be applied to the instance post-install |
| Ubuntu 24.04 cloud-init template | Operator creates on Proxmox pre-phase | Same workflow as existing Debian template; prerequisite for Splunk VM provisioning |
| VM ID range | New resources use IDs 206+; log server uses `ct_id`, Splunk uses `vm_id` | Existing resources occupy 201–205 (PKI, DNS, Nexus); field name follows config YAML schema (`ct_id` for LXCs, `vm_id` for VMs) |

---

## Component Summary

| Component | Type | Node | Always-on | Network | Lifecycle |
|---|---|---|---|---|---|
| Log Server | LXC | Production node | Yes | MGMT VLAN | Permanent (`enable_log_server`) |
| Splunk Enterprise | VM | Compute node | Normally-off | MGMT VLAN | Hackathon — 6-month dev license (`enable_splunk`) |

---

## Deployment Phases

### Pre-phase — Operator steps before any Terraform work

- [ ] Apply for Splunk Developer License (do immediately — processing takes days)
- [ ] Create Ubuntu 24.04 cloud-init VM template on Proxmox
- [ ] Add port `8089` to `Safe_ports` and `SSL_ports` in `.devcontainer/squid/squid.conf` (manual edit, distinct from `allowed-cidrs.conf`) → `make build` + reopen container
- [ ] Download Splunkbase `.tgz` files (MCP Server, AI Toolkit) to local disk — upload to Nexus deferred until Phase 1 step 1 (raw repo must exist first)

### Phase 1 — Infrastructure

**Gate:** Splunk UI accessible, MCP Server and AI Toolkit apps installed

1. Add `services.nexus.raw_hosted_repos` to config YAML + `bootstrap.yml` task loop + generator changes; run `make configure`; run Nexus playbook; upload Splunkbase `.tgz` files to raw repo
2. Deploy Log Server LXC (production node) — OTel Collector Contrib, syslog receiver + HEC exporter
3. Deploy Splunk Enterprise VM (compute node) — Ubuntu 24.04, sized per design decisions
4. Register DNS A records for log server and Splunk hostnames — **requires DNS infrastructure already operational (prior deployment phase)**
5. Install Splunk Enterprise, apply Developer License
6. Install MCP Server app via Ansible (fetch from Nexus raw repo, Splunk CLI install)
7. Install AI Toolkit app via Ansible (same pattern)
8. Restart Splunk; create RBAC user with `mcp_tool_execute` capability

### Phase 2 — Data

**Gate:** All priority sources flowing, visible in Splunk UI

9. Configure perimeter firewall syslog → Log Server (OTel syslog receiver)
10. Configure DNSdist query logs → Log Server
11. Configure Linux host rsyslog → Log Server on all MGMT LXCs
12. OTel Collector → Splunk HEC pipeline verified end-to-end

### Phase 3 — Integration (critical path gate)

**Gate:** End-to-end MCP pipeline working

13. Verify Squid connectivity: `curl` through proxy to Splunk port 8089 returns HTTP 200 — confirms `squid.conf` port entry and container rebuild are in place
14. Validate MCP Server app handshake
15. End-to-end: Claude Code ↔ MCP Server ↔ SPL query returns indexed results
16. Verify `| ai` command with Anthropic API key on a simple SPL query

### Phase 4 — Application (post-May 13)

**Gate:** Hackathon requirements published

17. Track selection (Security expected given data sources)
18. Demo scenario and narrative defined
19. Application form: Claude Code as MCP client vs custom web UI (Option C: both)
20. Finalize data sources — IDS logs? Nexus application logs?

---

## Integration with Existing Infrastructure

| Existing Service | Integration | Notes |
|---|---|---|
| PowerDNS | A records for log server and Splunk hostnames | Phase 1 step 4 — DNS infrastructure must already be operational; uses existing `dns-records.yml` playbook |
| Nexus | New `raw/hosted` repo + `services.nexus.raw_hosted_repos` config list | `bootstrap.yml` extended with task loop; `generate-configs.py` extended to emit `nexus_raw_hosted_repos` group var into inventory (parallel to `nexus_apt_proxy_repos` at lines 638–647) |
| PKI (step-ca) | Optional: TLS cert for Splunk port 8089 | Self-signed acceptable for hackathon; internal CA cert TBD at implementation |
| Squid proxy | Port 8089 added to `Safe_ports` and `SSL_ports` in `squid.conf` | Manual operator edit to `squid.conf` (not `allowed-cidrs.conf`); `make configure` does not handle port entries; requires dev container rebuild |
| MinIO | No direct integration | Terraform state backend only |
| config YAML | `services.splunk` (new flat VM key), `services.log_server` (new flat LXC key) | Generator's `validate_schema` does not reject unknown service keys (only asserts `pki`, `dns`, `nexus` are present) — new flat service keys are safe to add |
| config YAML | `services.nexus.raw_hosted_repos` (new subkey of existing nexus service) | Distinct from the two new flat service keys above; follows `apt_proxy_repos` sibling pattern under `services.nexus` |

---

## Implementation Notes

- **`generate-configs.py` — scope of changes required (both sessions):**
  - *`services.log_server` (Session 1):* New flat LXC service; generator must add a new named `if log_server:` block (alongside existing `if pki:` / `if dns:` / `if nexus:` blocks — there is no generic flat-service handler to extend) emitting `log_server_node`, `log_server_ct_id`, `log_server_ipv4_address`, `log_server_bridge`, `log_server_ipv4_gateway` into tfvars (`gen_tfvars`) and adding `log_server` host to inventory (`gen_inventory`). Note: if operator stubs `services.log_server` without an `ip` key, the generator will silently skip it — operators must provide all required fields before running `make configure`.
  - *`services.splunk` (Session 2):* New flat VM service; no existing flat VM code path to extend (all current VMs are nested under `pki`); generator must add a new named `if splunk:` block emitting `splunk_node`, `splunk_vm_id`, `splunk_ipv4_address`, `splunk_bridge`, `splunk_ipv4_gateway`, and `splunk_cloud_init_template_id` into tfvars, and add `splunk` host to inventory.
  - *`services.nexus.raw_hosted_repos` (Session 2):* Generator must read `services.nexus.raw_hosted_repos` and emit it as `nexus_raw_hosted_repos` group var under the `nexus` inventory group, parallel to `nexus_apt_proxy_repos` (lines 638–647).
- **`cloud_init_template_id` naming:** The existing global `cloud_init_template_id` in `variables.tf` refers to the Debian cloud-init template used by PKI root CA. The Splunk VM requires a separate Ubuntu 24.04 template emitted as `splunk_cloud_init_template_id` — a new, distinctly named tfvars variable. Both co-exist; no collision if named correctly.
- **OTel Collector syslog receiver** — beta stability as of early 2026; functional at homelab scale but validate against perimeter firewall's BSD syslog (RFC 3164) output during Phase 1.
- **Log server LXC teardown** — the `proxmox-lxc` module does not have a `stop_on_destroy` flag; destroy behaviour for a running container is provider-managed (see module comment — not guaranteed graceful). Verify clean teardown in sandbox before relying on it. When `enable_log_server` is eventually set to `false` (if ever), raw log files on the disk will be lost — take a backup first if log history must be preserved.
- **Log volume estimate** — 90 days / ~10–15 GB is an estimate. Verify against actual homelab log rates early in Phase 2 and resize if needed.
- **Ubuntu 24.04 template** — verify Splunk Enterprise compatibility matrix at download time.

---

## Open Items (deferred, not forgotten)

| Item | Deferred because |
|---|---|
| `ct_id` (206+) for log server, `vm_id` (206+) for Splunk VM | Operator fills at config time; use IDs outside existing 201–205 range |
| Static IP and FQDN for both services | Operator fills at config time before provisioning |
| TLS for Splunk port 8089 | Self-signed vs internal CA — TBD at implementation |
| Perimeter firewall IDS logs (eve.json) | Not a managed host; separate operational task post-May 13 |
| Demo narrative and final data source list | Depends on track judging criteria; post-May 13 |
| Track selection (Security / Observability / Platform) | Full criteria published May 13, 2026 |
| Submission form (Claude Code vs custom web UI) | Depends on track requirements |
| Nexus application logs as data source | Depends on demo story selected post-May 13 |
| MinIO migration to MGMT VLAN | Separate project; not blocked by or blocking Splunk |

---

## Ready for Planning

Design is complete. Two sequential planning sessions required — generator changes span both.

**Session 1 — Log Server LXC** (plan first; data pipeline depends on it)
Permanent MGMT VLAN LXC on production node. OTel Collector Contrib. 1 vCPU, 1 GB RAM, 100 GB disk,
Debian 13. Ansible role: OTel Collector install + config (syslog receiver UDP/TCP,
filelogreceiver, Splunk HEC exporter, file exporter for raw retention). PowerDNS A record.
`enable_log_server` boolean gate in root module.
Generator changes: `services.log_server` flat LXC path in `gen_tfvars` and `gen_inventory`.

**Session 2 — Splunk Enterprise VM + Nexus raw repo** (plan after log server is locked)
Hackathon VM on compute node. Ubuntu 24.04, meets Splunk minimums, `started = true`,
`start_on_boot = false`. Ansible playbook: Splunk install, Developer License, MCP Server +
AI Toolkit from Nexus raw repo, syslog/HEC inputs, RBAC user for MCP.
Nexus `services.nexus.raw_hosted_repos` config extension + `bootstrap.yml` task loop.
Generator changes: `services.splunk` flat VM named block; `splunk_cloud_init_template_id` new variable;
`services.nexus.raw_hosted_repos` → `nexus_raw_hosted_repos` inventory propagation. `enable_splunk` boolean gate.

> Run `/infra-plan` for the Log Server LXC first when ready to begin implementation.
