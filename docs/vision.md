# Homelab Vision — Planned Services

> Aspirational roadmap. All items subject to change — treat as design context, not requirements.
> Grouped roughly by theme; order within groups does not imply priority.

## Up Next

- **Management VLAN** — isolated segment housing DNS, PKI CAs, management interfaces, and infrastructure state storage (MinIO). Strict ingress from admin workstation; LAN → MGMT on service ports only. Controlled egress; no open internet access post-bootstrap. MinIO migration from current location planned.

- **Internal artifact mirror** — eliminates direct internet dependency from MGMT hosts. Tool TBD at design time. Phase 2 after MGMT VLAN is stable.

## Security & Compliance

- **Greenbone / OpenVAS** — vulnerability management.
- **Wazuh** — SIEM/EDR. Deployment form TBD.
- **Honeypot** (Cowrie) — deception layer; internal-first, DMZ placement possible later.

## DNS — Stage 3 (Deferred)

Requires Stage 1/2 validated in production first.

- **Encrypted transports** — DoT (port 853) and DoH on DNSdist; requires step-ca ACME cert on dns-dist.
- **RPZ / threat intel blocklists** — feed selection TBD; configure in Recursor.
- **DNSSEC** — signing on Auth + trust anchor rollout.
- **Reverse DNS (PTR zones)** — separate authoritative reverse zone per subnet.
- **GitOps record management** — OctoDNS or equivalent; separate design session after Netbox is live.
- **Webserver ACL expansion** — open Auth/Recursor/DNSdist metrics endpoints to LAN when Prometheus is deployed.

## Network

- **DMZ VLAN** — public-facing services segment with strict egress rules.
  - Possible: dedicated game server (e.g. Minecraft). May stay out of IaC scope if manual Docker is sufficient — separate effort TBD.

## Identity & Access

- **SSO / Identity provider** (Keycloak) — OIDC/SAML federation, integrates with AD when that exists.
- **RADIUS / 802.1X** — network-level auth; domain-joined devices authenticate at the switch/AP.
- **Password vault** — internal only (e.g. Vaultwarden).

## Observability

- **Monitoring stack** (Prometheus + Grafana) — metrics, alerting, on-call simulation.
- **Log aggregation** (Loki or Graylog) — centralized logs from all hosts; pairs with Wazuh.

## Infrastructure & Operations

- **IPAM / CMDB** (Netbox) — IP/subnet/VLAN/asset tracking; REST API for DNS automation.
- **Backup & recovery** — defined RPO/RTO targets, offsite replication simulation.
- **File share** — internal only, protocol TBD.

## Developer Tooling

- **GitLab** (MGMT VLAN) — self-hosted source control, CI/CD, and Terraform state backend (replacing MinIO post-bootstrap). Pull mirror of public GitHub repo. Production deployments triggered via pipeline with manual gate — operator reviews Terraform plan output and approves before apply runs. Production credentials never touch a developer machine; pipeline authenticates to Vault via JWT and fetches short-lived secrets at runtime.

- **HashiCorp Vault / Bitwarden Secrets Manager** (MGMT VLAN) — infrastructure secret backend. Machines and pipelines authenticate programmatically; secrets are never stored statically in CI variables or config files. Tool TBD — Vault if dynamic secrets or PKI integration needed, Bitwarden Secrets Manager if static secrets are sufficient.

- **chezmoi** (client-side, no infra) — dotfile and config manager across developer devices. Private Git repo (hosted on GitLab) as source; age encryption for sensitive files at rest; Vault/Bitwarden as secret injection backend at apply time. Manages `config/sandbox.yml` on the host so the devcontainer sees it without any changes to this repo.

- **Kubernetes cluster** — potential deployment target for personal projects.
- **Ghidra MCP server** — for fun / personal tooling.

## Long-term / Experimental

- **Windows Active Directory** (sandbox only, separate branch, far future)
  - Domain Controller, AD CS, Admin Center, and typical enterprise stack.
  - Goal: simulate a company acquisition/merger scenario.
  - Natural integration point for SSO federation and RADIUS.
