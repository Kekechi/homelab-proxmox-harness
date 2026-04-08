# Design: Ansible — PowerDNS Auth + Recursor (`dns-auth` LXC)

## Goal

Deploy PowerDNS Authoritative Server (5.0.x) and Recursor (5.4.x) on the
`dns-auth` LXC (CT 103). Auth serves internal zones; Recursor handles all
client queries, forwarding internal zone lookups to Auth and recursing to
the internet for everything else. This is Stage 1 of the DNS deployment.

## Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Role structure | Single self-contained role `pdns_auth_recursor` | Auth + Recursor are colocated; no shared Ansible infrastructure with DNSdist warranted yet — extract common role when DNSdist role is written if duplication bothers |
| APT repo | `trixie-auth-50` + `trixie-rec-54` on `repo.powerdns.com`, GPG key `FD380FBB`, no expiry | Trixie repos confirmed; key has no expiry (verified by operator via `gpg --show-keys`) |
| Config format | J2 templates — `pdns.conf.j2` (INI) for Auth, `recursor.yml.j2` (YAML) for Recursor 5.4 | Environment-specific values require templating; YAML is the current standard for Recursor 5.4+ |
| Zone variable | `{{ domain_name }}` from existing `group_vars/all/` | `domain_name` in config YAML already holds the full zone (`sandbox.example.com` / `lab.example.com`); no new variable or `generate-configs.py` change needed |
| Recursor listen address | `pdns_recursor_listen_address: "{{ ansible_host }}"` in `defaults/main.yml` | LXC has one NIC; explicit binding over `0.0.0.0` is defense-in-depth; `ansible_host` is the LAN IP; overridable |
| Zone bootstrap | Auth REST API — `POST /api/v1/servers/localhost/zones`, HTTP 422 = already exists → treat as OK | Idiomatic Ansible (`uri` module); idempotent without shell parsing |
| Service records | Out of scope — handled separately | Avoids coupling the DNS role to any service IP (MinIO, etc.) |
| Secret management | `PDNS_AUTH_API_KEY` + `PDNS_RECURSOR_API_KEY` in `.envrc`; `lookup('env', ...)` in tasks | Matches existing PKI pattern; same key used in config templates and `uri` API calls |
| Webserver `allow_from` | `127.0.0.1` only for both Auth (:8081) and Recursor (:8082) | No Prometheus scraper deployed yet; expand to LAN subnet when monitoring is added |
| `incoming.allow_from` | Use Recursor default (all RFC-1918 + loopback) | Default already covers sandbox subnet (10.x is in 10.0.0.0/8); no override needed |
| SQLite schema init | Ship schema as `files/pdns-sqlite3-schema.sql` in role | Official docs show schema inline only — no packaged `.sql` file path is documented; shipping in role avoids dependency on package internals |
| Verification | Auth API health → zone present → `dig` internal SOA → `dig` external A | Exercises full chain; `dnsutils` installed by role for ops use |

## Component Summary

| Component | Package | Config | Port | Service |
|---|---|---|---|---|
| Auth | `pdns-server` + `pdns-backend-sqlite3` | `/etc/powerdns/pdns.conf` | `127.0.0.1:5300` (DNS), `127.0.0.1:8081` (API) | `pdns` |
| Recursor | `pdns-recursor` | `/etc/powerdns/recursor.yml` | `<LAN_IP>:53` (DNS), `127.0.0.1:8082` (API) | `pdns-recursor` |

**Config format note:** Auth uses INI-style `pdns.conf`; Recursor 5.4 uses YAML `recursor.yml`.
Both are J2 templates.

**Key confirmed defaults (from official docs):**
- Auth `webserver-address` defaults to `127.0.0.1` — no override needed
- Recursor `incoming.listen` defaults to `[127.0.0.1, '::1']` — must be overridden to LAN IP in template
- Recursor `incoming.allow_from` defaults to all RFC-1918 — no override needed for homelab

## Changes Required Outside the Role

**`scripts/generate-configs.py`:**
- Add `PDNS_AUTH_API_KEY` and `PDNS_RECURSOR_API_KEY` to `_ENVRC_SECRET_VARS`
- Add both to the `gen_envrc()` template with `CHANGE_ME` placeholders

## Implementation Notes (for code generator)

These are not design decisions but constraints the role implementation must satisfy:

- **Task ordering:** create DB dir → apply schema (stat-guarded) → deploy `pdns.conf` → start `pdns` → `meta: flush_handlers` or `wait_for port: 5300` → zone bootstrap via API → deploy `recursor.yml` → start `pdns-recursor`
- **Auth before Recursor:** `pdns` must be started and port 5300 bound before `pdns-recursor` starts — Recursor logs warnings about unreachable forwarder on startup
- **`uri` tasks run on LXC, not controller:** `127.0.0.1:8081/8082` are loopback-only; no `delegate_to: localhost`
- **`setcap` for Recursor port 53:** Proxmox LXC seccomp blocks `AmbientCapabilities` (proven by PKI precedent). Include proactive `getcap` + conditional `setcap cap_net_bind_service=ep /usr/sbin/pdns_recursor` — same pattern as step-ca
- **Both Auth packages:** apt task must install `pdns-server` + `pdns-backend-sqlite3` + `dnsutils` + `sqlite3`
- **SQLite schema guard:** `stat` check on DB file before schema init; skip if already exists
- **`no_log: true`** on any task that touches API keys (config template, uri X-API-Key header)
- **`pdns.conf` permissions:** `mode: "0640"`, `owner: root`, `group: pdns`
- **`incoming.listen` YAML list:** must render as a list, not a scalar string
- **`webserver-address` explicit:** set `127.0.0.1` explicitly in template; do not rely on default
- **Assert env vars** at top of role (both `PDNS_AUTH_API_KEY` and `PDNS_RECURSOR_API_KEY`)

## Unvalidated Assumptions (verify on first deploy)

| Assumption | How to verify |
|---|---|
| Zone bootstrap HTTP status: design assumes 422 = already exists; some PDNS versions return 409 | Check Auth 5.0 API response on duplicate zone creation; adjust `failed_when` status list accordingly |
| SQLite WAL mode works in unprivileged LXC | Watch for permission errors on DB init task |
| Auth exposes Prometheus `/metrics` on its webserver | `curl http://127.0.0.1:8081/metrics` after first deploy — not documented on official settings page, only Graphite metrics are mentioned |

## Open Items (deferred)

| Item | Deferred to |
|---|---|
| Service A records (`minio`, etc.) | Separate task / playbook before resolver cutover |
| Webserver `allow_from` expansion | When Prometheus is deployed |
| Recursor RPZ config | DNSdist + Stage 3 session |
| DNSSEC on Auth | Post-Stage 1 session |

## Ready for Planning

Design is complete. Run `/infra-plan` with this document and `docs/dns-design.md` as input.

The plan should produce:
1. `ansible/roles/pdns_auth_recursor/` — full role
2. `ansible/playbooks/dns-setup.yml` — playbook targeting `dns_auth` group
3. Patch to `scripts/generate-configs.py` for two new env var entries
