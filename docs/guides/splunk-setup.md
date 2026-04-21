# Splunk Enterprise Setup Guide

Operational guide for deploying and maintaining the Splunk Enterprise instance via the `splunk` Ansible role.

---

## Prerequisites

### Files — upload to Nexus `splunk` raw repo before running

| File | Notes |
|---|---|
| `splunk-<version>-<build>-linux-amd64.deb` | Splunk Enterprise installer |
| `splunk-mcp-server_<ver>.tgz` | MCP Server app from Splunkbase |
| `splunk-ai-toolkit_<ver>.tgz` | AI Toolkit app from Splunkbase |
| Splunk license `.xml` | Optional — leave `splunk_license_file: ""` to run free tier |

### Checksums — update `ansible/roles/splunk/defaults/main.yml`

```bash
sha256sum splunk-<version>-<build>-linux-amd64.deb
sha256sum splunk-mcp-server_<ver>.tgz
sha256sum splunk-ai-toolkit_<ver>.tgz
```

Set `splunk_deb_checksum`, `splunk_app_mcp_checksum`, `splunk_app_aitoolkit_checksum` accordingly.

### Secrets — set in `.envrc` before running

```bash
export SPLUNK_ADMIN_PASSWORD="<strong password>"
export SPLUNK_HEC_TOKEN="$(uuidgen)"       # reuse this in OTel config (Session 2.3)
export SPLUNK_MCP_PASSWORD="<password>"
```

Then `direnv allow`.

---

## Running the Playbook

```bash
cd ansible
ansible-playbook playbooks/splunk-setup.yml
```

The playbook:
1. Runs the `common` role (base packages, internal CA trust, timezone)
2. Downloads and installs the Splunk `.deb` from Nexus
3. Sets the admin password via `user-seed.conf` (first run only)
4. Registers systemd boot-start and starts Splunkd
5. Installs MCP Server and AI Toolkit apps (skipped if already present)
6. Deploys `inputs.conf` with HEC global listener and `otelcol-hec` token
7. Restarts Splunk once to load all config
8. Creates `mcp-user` role with `mcp_tool_execute` capability
9. Creates `mcp` service account assigned to `mcp-user` role
10. Prints MCP token generation instructions

License installation is skipped when `splunk_license_file: ""` (free tier).

---

## Post-Deployment

### Generate MCP authentication token

The MCP Server uses encrypted tokens that can only be generated after the app is running. Run on the Splunk host (or via the REST API):

```bash
/opt/splunk/bin/splunk create-authtokens \
  -user mcp \
  -auth admin:<SPLUNK_ADMIN_PASSWORD>
```

Or via REST:

```bash
curl -k -u admin:<SPLUNK_ADMIN_PASSWORD> \
  -X POST https://<splunk-ip>:8089/services/authorization/tokens \
  -d "name=mcp&user=mcp&audience=mcp-server"
```

Save the returned token to `.envrc` as `SPLUNK_MCP_TOKEN`.

---

## Known Behaviors

**App installation idempotency:** App presence is detected by directory stat (`/opt/splunk/etc/apps/<AppDir>`). Re-running the playbook when apps are already installed skips the download and install entirely.

**App directory names:** The `splunk install app` CLI extracts apps using the internal app name, not the tarball filename:
- `splunk-mcp-server_<ver>.tgz` → `Splunk_MCP_Server`
- `splunk-ai-toolkit_<ver>.tgz` → `Splunk_ML_Toolkit`

**`apt cache update` always reports `changed`:** This is expected Ansible behavior for `update_cache: true`; it does not indicate a configuration drift.

**Splunk 10.x duplicate-user response:** Returns HTTP 400 (not 409) for an existing user. The role handles this with a pre-check GET before the POST.

**`splunk install app` requires running Splunk:** The CLI connects to the local management port to install apps. The `Wait for Splunk management port` task in `install.yml` ensures Splunk is ready before `apps.yml` runs.

---

## Upgrading Splunk or Apps

1. Upload the new `.deb` or `.tgz` to Nexus
2. Update the filename and checksum in `ansible/roles/splunk/defaults/main.yml`
3. For apps: manually remove `/opt/splunk/etc/apps/<AppDir>` on the host before re-running (the stat-based skip prevents re-install otherwise)
4. Re-run the playbook

---

## Deferred Items

| Item | Session |
|---|---|
| OTel Collector HEC exporter → Splunk | Session 2.3 |
| Syslog inputs (firewall, DNS, rsyslog) | Phase 2 |
| MCP connectivity testing through Squid | Phase 3 |
| TLS on port 8089 via internal CA | Post-hackathon |
