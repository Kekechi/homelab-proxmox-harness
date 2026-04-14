# Design: Ansible — PowerDNS DNSdist (`dns-dist` LXC)

## Goal

Deploy DNSdist 2.1.x on the `dns-dist` LXC. DNSdist is the client-facing DNS
frontend: it accepts queries from trusted VLANs on port 53 and forwards them to the
PowerDNS Recursor on the `dns-auth` LXC. This is Stage 2 of the DNS deployment.
DoT/DoH/DoQ termination, RPZ, and client migration are explicitly out of scope.

## Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Role structure | New self-contained `pdns_dnsdist` role | Separate LXC, separate concern; APT setup duplication (~3 tasks) is below the extract threshold; consistent with existing role strategy |
| Config format | YAML (`dnsdist.yml`) — dnsdist 2.1.x native format | YAML officially supported since 2.0 (verified from official docs); 2.1.x is current stable; consistent with Recursor's YAML approach; Jinja2 templates work normally |
| APT channel | `trixie-dnsdist-21` on `repo.powerdns.com` | Same GPG key (`FD380FBB`) as auth role; keyring path `/etc/apt/keyrings/dnsdist-21-pub.asc` follows PowerDNS official install convention — self-documenting on the dist LXC; avoids `pdns.asc` ambiguity on a host with no pdns-server/recursor |
| Backend pool | Recursor at `pdns_recursor_address:53` — generator-emitted group var | `services.dns.auth.ip` already in config YAML; generator strips prefix and emits bare IP as `pdns_recursor_address` group var for `dns_dist`; consistent with how the project handles cross-service addressing (cf. `minio_ca_url`); avoids hardcoded hostnames in role |
| Listen binding | `{{ ansible_host }}:53` (LAN IP) | Explicit binding over `0.0.0.0`; consistent with Recursor pattern; defense-in-depth for single-NIC LXC; DNSdist binds UDP + TCP on a single entry |
| ACL policy | Explicit list `pdns_dnsdist_acl_cidrs` — generator-populated from `infrastructure.network.cidr` | RFC-1918 rejected: future DMZ hosts are RFC-1918 and must not resolve internal zones; explicit allow-list ensures new networks must be consciously added as trusted; generator emits `pdns_dnsdist_acl_cidrs` group var for `dns_dist` |
| Webserver/API | `127.0.0.1:8083`, `PDNS_DNSDIST_API_KEY` env var | Consistent loopback-only pattern (Auth: 8081, Recursor: 8082, DNSdist: 8083); expand `allow_from` when Prometheus deployed |
| Console | Not enabled for Stage 2 — noted as extension point | Useful for live debugging (`delta()`, runtime server add/remove) but no operational need yet; enable when debugging value justifies complexity |
| Port 53 / setcap | `setcap cap_net_bind_service=ep <dnsdist-binary>` — same pattern as Recursor | Proxmox LXC seccomp blocks `AmbientCapabilities` (proven by PKI precedent); conditional `getcap` check before `setcap` |
| Playbook | New `ansible/playbooks/dns-dist-setup.yml` | dns-auth already deployed; separate playbook keeps deployments independent and avoids re-running auth plays; aligns with Ansible best practice: separate playbooks for separate purposes |

## Component Summary

| Component | Package | Config | Port | Service |
|---|---|---|---|---|
| DNSdist | `dnsdist` | `/etc/dnsdist/dnsdist.yml` | `<LAN_IP>:53` (DNS), `127.0.0.1:8083` (API) | `dnsdist` |

**Config format note:** DNSdist 2.0+ uses YAML natively (`dnsdist.yml`). Lua config (`dnsdist.conf`) is legacy. YAML is the correct format for 2.1.x installs.

## Changes Required Outside the Role

**`scripts/generate-configs.py`:**

*`gen_inventory()` — nested service handler:* The `dns` service is nested (no top-level `ip`), so it goes through the `for subkey, sub in svc.items()` loop (lines ~313–325). Extend this loop to detect the `dns_dist` group and emit group vars before the `hosts:` block:

```python
group = f"{svc_name}_{subkey}"   # → "dns_dist"
# existing lines emit group + hosts...
# ADD: when group == "dns_dist", emit vars block:
if group == "dns_dist":
    auth_sub = svc.get("auth", {})
    recursor_ip = _strip_prefix(auth_sub.get("ip", ""))
    network_cidr = infra.get("network", {}).get("cidr", "")
    lines.append(f"      vars:")
    lines.append(f"        pdns_recursor_address: {recursor_ip}")
    lines.append(f"        pdns_dnsdist_acl_cidrs:")
    lines.append(f"          - \"{network_cidr}\"")
```

Note: `gen_inventory()` currently does not receive `infra` as a parameter — pass `cfg` into the detection block or derive `infra = cfg.get("infrastructure", {})` at the top of the function.

*`_ENVRC_SECRET_VARS` list:* Add `"PDNS_DNSDIST_API_KEY"` after `"PDNS_RECURSOR_API_KEY"`.

*`gen_envrc()` template:* Add after the existing PowerDNS block:
```python
export PDNS_DNSDIST_API_KEY="{CHANGE_ME}"      # DNSdist webserver/API key
```

## Implementation Notes (for code generator)

These are not design decisions but constraints the role implementation must satisfy:

- **Task ordering:** install package → `setcap` (conditional) → deploy `dnsdist.yml` → start `dnsdist`
- **`setcap` guard:** `getcap` result registered; `setcap` runs only if `cap_net_bind_service` not already present — same pattern as Recursor role
- **Binary path unknown:** use `ansible.builtin.command: which dnsdist` or `dpkg -L dnsdist` in a task to locate binary before `setcap`; alternatively verify path in unvalidated assumptions below
- **YAML config syntax:** verify full YAML settings reference at `dnsdist.org/reference/yaml-settings.html` before generating template — 2.0+ YAML format was recently introduced and training knowledge may lag
- **`no_log: true`** on any task that touches `PDNS_DNSDIST_API_KEY`
- **Assert env var** at top of role (`PDNS_DNSDIST_API_KEY`)
- **Health check:** DNSdist health-checks backends by DNS query by default — no explicit health check config expected for Stage 2; verify default is active in YAML format
- **DEB822 sources file:** use `ansible.builtin.copy` with DEB822 format; `Signed-By: /etc/apt/keyrings/dnsdist-21-pub.asc`
- **APT pin:** write `/etc/apt/preferences.d/dnsdist` (not `pdns` — the existing auth role owns that file on a different LXC, but be explicit to avoid confusion):
  ```
  Package: dnsdist
  Pin: origin repo.powerdns.com
  Pin-Priority: 600
  ```
  The `pdns-*` glob used in the auth role does not match the `dnsdist` package name — a separate pin is required.
- **`pdns_recursor_address` and `pdns_dnsdist_acl_cidrs`** are group vars injected by the generator — treat as inventory variables in the role, do not put them in `defaults/main.yml`
- **Verify task:** include a `tasks/verify.yml` sub-task (called from `main.yml`) that exercises the full forward path:
  - `dig @127.0.0.1 <domain_name> SOA` — internal zone resolves through DNSdist → Recursor → Auth
  - `dig @127.0.0.1 google.com A` — external recursion works
  - `curl -sf http://127.0.0.1:8083/` — webserver responds (HTTP 200 or 401 with API key)
  - `dnsutils` must be installed by the role (`apt` task) for `dig`
- **`common` role:** `dns-dist-setup.yml` must include a play targeting `dns_dist` with `roles: [common]` before the `pdns_dnsdist` role play — same pattern as `dns-setup.yml`

## Unvalidated Assumptions (verify on first deploy)

| Assumption | How to verify |
|---|---|
| DNSdist binary path is `/usr/bin/dnsdist` | `dpkg -L dnsdist \| grep bin` after install |
| YAML config syntax for 2.1.x is stable and fields match training knowledge | Fetch `dnsdist.org/reference/yaml-settings.html` during code gen; do not assume field names |
| Default health check (DNS query to backend) is active in YAML config without explicit config | Check DNSdist logs on first deploy for health check activity |
| Zone duplicate response not applicable (DNSdist has no zone concept) | N/A — confirmed |

## Open Items (deferred, not forgotten)

| Item | Deferred to |
|---|---|
| DoT termination (port 853) | Stage 3 — requires step-ca ACME cert on dist LXC |
| DoH termination (port 443) | Stage 3 — same cert requirement |
| DoQ (DNS over QUIC) | Stage 3+ |
| RPZ config | Stage 3+ — configured on Recursor, not DNSdist |
| Client migration (DHCP cutover) | Separate operational runbook after DNSdist verified |
| Existing resolver disable | Same runbook as client migration |
| Console enable | Extension point — enable when live debugging is needed |
| Webserver `allow_from` expansion | When Prometheus is deployed |
| Netbox integration | Way later |

## Ready for Planning

Design is complete. Run `/infra-plan` or `/ansible-deploy` with this document as input.

The plan should produce:
1. `ansible/roles/pdns_dnsdist/` — full role (tasks/apt, tasks/main, tasks/verify, templates/dnsdist.yml.j2, defaults/main.yml, handlers/main.yml)
2. `ansible/playbooks/dns-dist-setup.yml` — two plays: `common` role on `dns_dist`, then `pdns_dnsdist` role on `dns_dist`
3. Patch to `scripts/generate-configs.py` for `pdns_recursor_address`, `pdns_dnsdist_acl_cidrs` group vars, and `PDNS_DNSDIST_API_KEY` in envrc
