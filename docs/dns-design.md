# Design: Internal DNS Server (PowerDNS)

## Goal

Deploy an internal authoritative DNS server for private zones (`sandbox.<domain>`,
`lab.<domain>`), with a recursive resolver and encrypted DNS frontend. Follows the same
environment pattern as PKI: sandbox VLAN now, management VLAN in production, same Ansible
code configured differently per environment.

Replaces the temporary resolver on the network gateway. The gateway's built-in resolver will
be disabled entirely — clients use PowerDNS via DNSdist. The gateway itself will also use
DNSdist (accepts the infrastructure dependency; routing and firewalling function without DNS).

---

## Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Software | PowerDNS (Auth + Recursor + DNSdist) | API-driven, Netbox integration path, RPZ support, operator-grade architecture |
| Auth backend | SQLite (WAL mode) | Officially supported for small deployments; same schema as PostgreSQL for future migration |
| LXC count | 2 LXCs | Auth+Recursor colocated (Auth on loopback, per official migration guide); DNSdist separate |
| Auth binding | `127.0.0.1:5300` | Unreachable from network; zero attack surface |
| Recursor binding | LAN IP:53 | Receives forwarded queries from DNSdist |
| DNSdist binding | LAN IP:53 (plain) + :853/:443 (DoT/DoH) | Client-facing; terminates encrypted DNS |
| Client resolver | DNSdist IP (via DHCP) | Single advertised resolver; Recursor handles both internal and internet recursion |
| Gateway built-in resolver | Disable entirely | Clean cut; network functions without DNS; avoids partial-fallback confusion |
| Gateway system DNS | DNSdist IP | Gateway itself uses PDNS; accepts infrastructure dependency |
| Recursor → Auth | `forward-zones` (RD=0) | Correct for authoritative backend; `auth-zones` would bypass Auth server |
| High availability | Single instance, accepted SPOF | Homelab scope; add second instance later if needed |
| Package source | `repo.powerdns.com` | Distro packages lag significantly (e.g. Debian 12 ships Auth 4.7, current is 4.9+) |
| Monitoring | Native `/metrics` Prometheus endpoint | All three components expose it natively; no external exporter needed |

---

## Component Summary

| Component | Runs on | Listens on | Always-on |
|---|---|---|---|
| PowerDNS Authoritative | LXC 1 | `127.0.0.1:5300` | Yes |
| PowerDNS Recursor | LXC 1 | `<LXC1-LAN-IP>:53` | Yes |
| DNSdist | LXC 2 | `<LXC2-LAN-IP>:53` (plain), `:853` (DoT), `:443` (DoH) | Yes |

**Data flow:**
```
Clients ──► DNSdist (LXC 2, :53/:853/:443)
                │
                ▼
         Recursor (LXC 1, :53)
          │              │
          ▼              ▼
    Auth (LXC 1,    Internet root
     loopback:5300)   servers
    [internal zones]  [public zones]
```

**Environment mapping** (same code, different config):

| | Sandbox | Production |
|---|---|---|
| VLAN | Sandbox VLAN | Management VLAN (not yet created) |
| Zones | `sandbox.<domain>` | `lab.<domain>` |
| LXC IPs | TBD — infra-plan | TBD — infra-plan |

---

## Pre-Deploy Checklist (Stage 1)

Before cutover, migrate existing records from the gateway resolver to PDNS Auth:
- [ ] Existing internal service A records

---

## Open Items (deferred, not forgotten)

| Item | Deferred to |
|---|---|
| IP allocation for both LXCs | `/infra-plan` |
| Reverse DNS (PTR records for sandbox subnet) | `/infra-plan` — separate authoritative reverse zone |
| RPZ feed selection (threat intel blocklists) | Recursor deploy session |
| DNSSEC signing + trust anchor distribution | Post-Stage 1 session |
| DoH/DoT certificate via step-ca ACME | DNSdist deploy session |
| OctoDNS / GitOps record management | Post-Stage 1 session |
| Production deployment | Blocked — Management VLAN not yet created |
| Netbox integration | When Netbox is deployed |

## Unvalidated Assumptions (verify during deploy)

- `forward-zones` in Recursor bypasses `do-not-query` RFC1918 block — expected yes per docs, confirm on first run
- Gateway DHCP can advertise LXC IP as DNS server — standard config, confirm in gateway UI
- step-ca wildcard `*.sandbox.<domain>` covers DNSdist hostname — confirm ACME policy allows it

---

## Ready for Planning

Design is complete. Run `/infra-plan` with this document as input.

Suggest staging the deployment:
1. **Stage 1:** Both LXCs + Auth + Recursor. Gateway forwards internal zones to Recursor. Validate internal resolution.
2. **Stage 2:** DNSdist on LXC 2. Migrate DHCP to advertise DNSdist. Disable gateway built-in resolver.
3. **Stage 3 (later):** DoT/DoH on DNSdist, RPZ on Recursor, DNSSEC on Auth.
