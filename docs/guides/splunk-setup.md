# Splunk Enterprise Setup Guide

Operational guide for deploying and maintaining the Splunk Enterprise instance via the `splunk` Ansible role.

> **Deprecation-planned.** Splunk is heavy (it occupies a whole node) and is slated for removal. Do **not** add new Splunk couplings. Services emit logs to the syslog → otelcol log-server layer, which sinks to the object store (`awss3`) by default; the Splunk HEC exporter is optional and disabled unless `services.splunk.enabled` is true. New log integrations should target the syslog/otelcol path, not Splunk. (Wazuh is under consideration as a replacement.)
>
> Splunk is **off by design** in sandbox (`services.splunk.enabled: false`), so `make verify-all` and the deploy loop skip it gracefully.

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
export SPLUNK_HEC_TOKEN="$(uuidgen)"       # also wire into otelcol's HEC exporter when enabled
export SPLUNK_MCP_PASSWORD="<password>"
export STEP_CA_PROVISIONER_PASSWORD="<provisioner password>"  # required only when splunk_tls_enabled
```

The playbook's pre-flight play asserts all four are present (the `splunk-setup.yml`
localhost pre-flight requires `STEP_CA_PROVISIONER_PASSWORD` because it also runs the
`step_client` role). It also requires `NEXUS_READER_PASSWORD` for the Nexus apt/raw
download (set when Nexus is deployed).

Then `direnv allow`.

---

## Running the Playbook

```bash
cd ansible
ansible-playbook playbooks/splunk-setup.yml
```

The playbook runs three plays against the `splunk` host (after a localhost secrets
pre-flight): the `common` role, then `step_client` (cert client + renewal), then the
`splunk` role. The `splunk` role (`tasks/main.yml`) does, in order:

1. Asserts secrets and the three pinned checksums are set (not `sha256:CHANGE_ME`)
2. **Install** (`install.yml`): downloads the `.deb` from Nexus and installs it; seeds the admin password via `user-seed.conf` (first run only — detected by the absence of `/opt/splunk/etc/passwd`); registers systemd boot-start; enables and starts `Splunkd`; waits for the management port
3. **TLS** (`tls.yml`) — only when `splunk_tls_enabled`: issues a cert from the issuing CA via the `step` client, writes `splunkd.pem`, sets `enableSplunkdSSL=true` in `server.conf`, and installs a `splunk-cert-renew` systemd timer (see TLS section below). Skipped with a warning if the issuing CA is unreachable.
4. **License** (`license.yml`): skipped when `splunk_license_file: ""` (free tier)
5. **Apps** (`apps.yml`): installs MCP Server and AI Toolkit apps (skipped if already present — see idempotency note)
6. **Configure** (`configure.yml`): deploys `inputs.conf` with the HEC global listener and the `otelcol-hec` token
7. Flushes handlers — a single Splunk restart covers license, apps, and `inputs.conf`
8. **Verify** (`verify.yml`): waits for the management API to respond `200`
9. **RBAC** (`rbac.yml`): creates the `mcp-user` role, adds the `mcp_tool_execute` capability (in a second call, after the app is loaded), then creates the `mcp` service account assigned to `mcp-user`
10. **Debug** (`debug.yml`): prints MCP token generation instructions

---

## Post-Deployment

### Generate MCP authentication token

The MCP Server uses encrypted tokens that can only be generated after the app is running. Run on the Splunk host (or via the REST API):

```bash
/opt/splunk/bin/splunk create-authtokens \
  -user mcp \
  -auth admin:<SPLUNK_ADMIN_PASSWORD>
```

Or via REST (run on the host — the role's own post-deploy message uses `localhost`):

```bash
curl -k -u admin:<SPLUNK_ADMIN_PASSWORD> \
  -X POST https://localhost:8089/services/authorization/tokens \
  -d "name=mcp&user=mcp&audience=mcp-server"
```

The management port (`8089`) is always HTTPS in these examples; `-k` skips verification
because the cert is either Splunk's self-signed default or, when `splunk_tls_enabled`, an
internal-CA cert (see TLS section). Save the returned token to `.envrc` as
`SPLUNK_MCP_TOKEN`.

---

## Known Behaviors

**App installation idempotency:** App presence is detected by directory stat (`/opt/splunk/etc/apps/<AppDir>`). Re-running the playbook when apps are already installed skips the download and install entirely.

**App directory names:** The `splunk install app` CLI extracts apps using the internal app name, not the tarball filename:
- `splunk-mcp-server_<ver>.tgz` → `Splunk_MCP_Server`
- `splunk-ai-toolkit_<ver>.tgz` → `Splunk_ML_Toolkit`

**`apt cache update` always reports `changed`:** This is expected Ansible behavior for `update_cache: true`; it does not indicate a configuration drift.

**Splunk 10.x duplicate-user response:** Returns HTTP 400 (not 409) for an existing user. The role handles this with a pre-check GET before the POST.

**`splunk install app` requires running Splunk:** The CLI connects to the local management port to install apps. The `Wait for Splunk management port` task in `install.yml` ensures Splunk is ready before `apps.yml` runs. (Verify also re-checks the management API in `verify.yml` before RBAC runs.)

**HEC index:** the deployed `inputs.conf` (`otelcol-hec` token) targets `index = main`. The otelcol log-server pipeline, however, tags events with `com.splunk.index = homelab-logs`. If you enable the otelcol Splunk HEC exporter, create the `homelab-logs` index in Splunk first (events tagged to a missing index are dropped). This index mismatch is intentional during the deprecation window — the default sink is the object store, not Splunk.

**RBAC status codes:** role creation accepts `201` (created) or `409` (exists); the capability POST always returns `200` (treated as unchanged); the `mcp` user is created only when a pre-check `GET` returns `404` (Splunk 10.x returns `400`, not `409`, on a duplicate `POST` — the GET-first pattern avoids it).

---

## Upgrading Splunk or Apps

1. Upload the new `.deb` or `.tgz` to Nexus
2. Update the filename and checksum in `ansible/roles/splunk/defaults/main.yml`
3. For apps: manually remove `/opt/splunk/etc/apps/<AppDir>` on the host before re-running (the stat-based skip prevents re-install otherwise)
4. Re-run the playbook

---

## TLS on the Management Port (8089)

Implemented in `tasks/tls.yml`, gated on `splunk_tls_enabled` (default `false`;
propagated from `config/<env>.yml` via `make configure` into the inventory group vars,
along with `splunk_domain` and `splunk_ca_url` — do not hardcode them in role defaults).

When enabled, the role:
- Checks the issuing CA `/health` first; if unreachable it **skips TLS with a warning** (run the PKI playbook, then re-run the Splunk playbook to complete TLS)
- Issues a short-lived EC P-256 cert for `splunk_domain` via the `step ca certificate` client using the JWK provisioner (`splunk_jwk_provisioner`, default `acme` — a provisioner name, not the ACME protocol), writing `cert.crt`/`cert.key` under `splunk_certs_dir` (`/opt/splunk/etc/auth/step-ca`)
- Assembles `splunkd.pem` (key + cert) and sets `enableSplunkdSSL`, `serverCert`, `sslRootCAPath`, and `requireClientCert=false` in `server.conf`
- Installs a `splunk-cert-renew.timer` (runs ~every 15 min, renews only when the cert needs it, then restarts `Splunkd`)

Certificate issuance is skipped when `cert.crt` already exists; permissions are
re-hardened on every run.

---

## Deferred Items

| Item | Status |
|---|---|
| OTel Collector HEC exporter → Splunk | Implemented but **disabled by default** (`otelcol_splunk_hec_enabled`, on only when `services.splunk.enabled`). Default sink is the object store. |
| Syslog inputs (firewall, host auth, DNS) | DNS + host-auth syslog flow through the otelcol log server today; firewall logs pending |
| MCP connectivity testing through the dev-container proxy | Pending |
