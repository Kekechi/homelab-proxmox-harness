# Homelab Vision — Planned Services

> Aspirational roadmap. All items subject to change — treat as design context, not requirements.
> Grouped roughly by theme; order within groups does not imply priority.

## Up Next

- **DNS server** — internal authoritative resolver. Preference for something simple.

- **Management VLAN** — isolated segment housing DNS, PKI CAs, management interfaces, and infrastructure state storage (MinIO). Strict ingress from admin workstation; LAN → MGMT on service ports only. Controlled egress; no open internet access post-bootstrap. MinIO migration from current location planned.

- **Internal artifact mirror** — eliminates direct internet dependency from MGMT hosts. Tool TBD at design time. Phase 2 after MGMT VLAN is stable.

## Security & Compliance

- **Greenbone / OpenVAS** — vulnerability management.
- **Wazuh** — SIEM/EDR. Deployment form TBD.
- **Honeypot** (Cowrie) — deception layer; internal-first, DMZ placement possible later.

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

- **Kubernetes cluster** — potential deployment target for personal projects.
- **Ghidra MCP server** — for fun / personal tooling.

## Long-term / Experimental

- **Windows Active Directory** (sandbox only, separate branch, far future)
  - Domain Controller, AD CS, Admin Center, and typical enterprise stack.
  - Goal: simulate a company acquisition/merger scenario.
  - Natural integration point for SSO federation and RADIUS.
