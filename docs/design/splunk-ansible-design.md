# Design: Splunk Enterprise Ansible Deployment (Session 1.6)

## Goal

Deploy and configure Splunk Enterprise on the provisioned Ubuntu 24.04 VM via Ansible. This
session covers software installation, license application, Splunkbase app deployment (MCP Server
+ AI Toolkit), HEC input configuration, and RBAC setup. The result is a running Splunk instance
accessible on the MGMT VLAN with an MCP endpoint ready for AI agent integration.

---

## Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Installer source + format | `.deb` from Nexus raw repo `splunk` | Consistent with `otelcol-contrib` `.deb` pattern; `apt: deb:` Ansible task is familiar; `/opt/splunk` fixed path is fine for single-instance homelab; Nexus `splunk` raw repo holds both the installer and Splunkbase app `.tgz` files pre-staged by operator |
| Configuration approach | Mixed: `user-seed.conf` (admin password), CLI (license + app install), `inputs.conf` template (HEC), REST API `uri:` (RBAC) | Each method matches the phase's native interface; `user-seed.conf` is the only option before `etc/passwd` exists; CLI is the documented path for license and app installs; `inputs.conf` is the native Splunk config interface for inputs; REST API is the documented management path for users and roles |
| Input configuration | HEC global listener (`[http]` port 8088) + single `otelcol-hec` token stanza | No other inputs ready this session; syslog sources are Phase 2; stub-only inputs add noise without a receiver |
| App installation | MCP Server → AI Toolkit sequential via `splunk install app`; one restart after both; `-update 1` for idempotency | No functional ordering dependency between apps; single restart covers both; `-update 1` makes re-runs safe |
| RBAC + secrets | One `mcp` service account; `mcp-user` role with `mcp_tool_execute` capability; operator-supplied HEC token UUID; secrets in `.envrc` as `SPLUNK_ADMIN_PASSWORD`, `SPLUNK_HEC_TOKEN`, `SPLUNK_MCP_PASSWORD`; playbook pre-flight asserts all three non-empty | Operator-supplied HEC token allows OTel config to be pre-staged before Session 2.3; `.envrc` pattern matches all other roles in this repo |
| Service management | First start → license → apps → `inputs.conf` → one handler-triggered restart → RBAC REST calls; `notify` fires restart only on `changed` | Collapses redundant restarts; handler pattern is idempotent on re-runs; RBAC via REST runs after final restart when Splunk is fully configured |

---

## Deferred

| Item | Deferred to |
|---|---|
| OTel Collector HEC exporter pointing at Splunk | Session 2.3 |
| Syslog inputs (firewall, DNSdist, rsyslog) | Phase 2 |
| MCP connectivity testing through Squid | Phase 3 |
| TLS on port 8089 via internal CA | Post-hackathon |

---

## Known Constraints

**MCP token gap:** MCP Server uses encrypted public-key tokens that can only be generated from
the MCP Server app UI. No REST API or CLI path exists. Standard Splunk auth tokens
(`POST /services/authorization/tokens`) do not work for MCP. The playbook ends with a `debug`
task printing operator instructions to generate the token manually and save it to `.envrc`.

**Systemd not auto-created:** The Splunk `.deb` installer does not create a systemd unit.
The playbook must run `splunk enable boot-start -systemd-managed 1 -user splunk -group splunk`
explicitly before enabling and starting the service.

---

## Role and Playbook Structure

```
ansible/
  roles/splunk/
    defaults/main.yml       splunk_version, splunk_app_mcp_filename, splunk_app_aitoolkit_filename
    tasks/
      main.yml              pre-flight asserts + role orchestration
      install.yml           download .deb from Nexus, apt: deb:, first-start, systemd boot-start
      license.yml           splunk add licenses CLI, notify restart
      apps.yml              splunk install app (MCP Server, AI Toolkit), notify restart
      configure.yml         inputs.conf template (HEC), notify restart
      rbac.yml              uri: REST — create mcp-user role, create mcp user
      debug.yml             debug task — MCP token generation instructions
    templates/
      inputs.conf.j2        [http] + [http://otelcol-hec] stanzas
      user-seed.conf.j2     HASHED_PASSWORD for admin
    handlers/main.yml       Restart Splunk (splunk restart via systemd)
  playbooks/splunk-setup.yml
    - Pre-flight: assert SPLUNK_ADMIN_PASSWORD, SPLUNK_HEC_TOKEN, SPLUNK_MCP_PASSWORD non-empty
    - hosts: splunk, roles: [splunk]
```

---

## Operator Pre-requisites

Before running the playbook, the operator must:

1. Upload Splunk Enterprise `.deb` to Nexus raw repo `splunk`
2. Upload MCP Server app `.tgz` to Nexus raw repo `splunk`
3. Upload AI Toolkit app `.tgz` to Nexus raw repo `splunk`
4. Upload Splunk Developer license `.xml` to a path accessible from the controller
5. Set `.envrc`:
   - `SPLUNK_ADMIN_PASSWORD` — strong password for the `admin` account
   - `SPLUNK_HEC_TOKEN` — UUID (generate with `uuidgen`); reuse this value in OTel config (Session 2.3)
   - `SPLUNK_MCP_PASSWORD` — password for the `mcp` service account

After the playbook completes:

6. Open Splunk Web → MCP Server app → Generate Token → save to `.envrc` as `SPLUNK_MCP_TOKEN`
