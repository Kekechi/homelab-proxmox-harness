# Design: OTel Collector Log Server (Session 1.3)

## Goal

Deploy OpenTelemetry Collector Contrib on the Log Server LXC as a permanent, always-on
central syslog gateway for the homelab MGMT VLAN. The collector receives syslog from all
managed hosts and network devices, and forwards logs to MinIO for durable 365-day retention.
This infrastructure survives Splunk's expiry — sources never need reconfiguration when the
downstream backend changes; only the OTel exporter config is updated.

The Splunk HEC exporter is intentionally deferred to Session 2.3, when Splunk Enterprise is
running and a real HEC token exists. This session delivers a fully operational collection and
retention pipeline that can be extended with a fanout exporter later.

---

## Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Installation method | `get_url` + `dpkg` with `otelcol-contrib` DEB from GitHub releases | Official documented installation path at opentelemetry.io/docs/collector/install; DEB installs systemd unit automatically. Note: an APT repo at `packages.opentelemetry.io` may also exist — verify at role-writing time; prefer APT per ansible-workflow rule if confirmed stable |
| OTel distribution | `otelcol-contrib` | Core (`otelcol`) lacks syslog receiver and awss3exporter; contrib required |
| DEB idempotency | `dpkg-query -W otelcol-contrib` version check; skip download+install if already at pinned version | `dpkg -i` is not idempotent; version check prevents re-install on every run |
| Version pinning | Version pinned in role defaults (`otelcol_version`) | Reproducible installs; operator bumps version variable to upgrade |
| Syslog transport | TCP only | All sources (OPNsense, rsyslog, DNSdist) are configurable; TCP gives delivery guarantees; no UDP message truncation |
| Syslog port | 1514 | IANA de facto standard unprivileged syslog port; unprivileged LXC cannot bind <1024; corrects port 5140 in `main.tf` comment (comment-only change, no resource impact) |
| Syslog format | RFC 5424 only | OPNsense supports RFC 5424 via UI checkbox; rsyslog defaults to RFC 5424; single format simplifies pipeline |
| Log retention backend | MinIO (`awss3exporter`) | S3 object storage is the industry pattern for durable log retention at a gateway; MinIO already deployed on MGMT VLAN; endpoint-agnostic config allows retargeting to GitLab object storage post-GitLab migration |
| Retention period | 365 days via MinIO bucket lifecycle policy (`mc ilm add`) | Enterprise baseline (PCI-DSS: 12 months); negligible storage cost at homelab log volumes; lifecycle policy is a Day-2 ops step, not in OTel config |
| MinIO bucket | `otelcol-logs` | Clearly scoped name; dedicated bucket isolates log data from Terraform state |
| S3 path style | `s3_force_path_style: true` | Required for MinIO (path-style addressing) |
| S3 object prefix | Default `year=%Y/month=%m/day=%d/hour=%H/minute=%M` (strftime) | OTel exporter built-in default; time-partitioned prefix is industry standard; enables efficient time-range retrieval |
| MinIO IAM user | Provisioned by Ansible `bucket.yml` tasks delegated to controller (`delegate_to: localhost`) using `mcli` binary | `mcli` is present on the Ansible controller (dev container); consistent with `bootstrap-minio.sh` pattern; `mc` is not installed on the LXC target and should not be |
| mcli alias in `bucket.yml` | `bucket.yml` creates alias `homelab-minio-otelcol` using `MINIO_ENDPOINT` + `MINIO_ROOT_USER` + `MINIO_ROOT_PASSWORD` (all already in `.envrc`) via `mcli alias set`; uses that alias for all admin operations | Same pattern as `bootstrap-minio.sh` line 57; admin credentials required for `mcli admin user add`; no new env vars needed for the alias setup |
| MinIO IAM policy | `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket`, `s3:GetBucketLocation` scoped to `otelcol-logs` bucket and `otelcol-logs/*` | Matches `bootstrap-minio.sh` proven policy set; `awss3exporter` requires at minimum `GetBucketLocation` + `PutObject`; `ListBucket` needed for partition detection |
| Credential pre-requisite | Operator decides `OTELCOL_MINIO_ACCESS_KEY` / `OTELCOL_MINIO_SECRET_KEY` values upfront, adds to `.envrc` before running playbook | `configure.yml` templates the config file before `bucket.yml` runs — credentials must exist in the environment before the play starts; role creates the IAM user with these same credentials (not generates new ones) |
| Credentials in `.envrc` | `OTELCOL_MINIO_ACCESS_KEY` / `OTELCOL_MINIO_SECRET_KEY` added to both `_ENVRC_SECRET_VARS` (preservation) and `gen_envrc()` (emission with `CHANGE_ME` placeholder) | Both changes required: `_ENVRC_SECRET_VARS` preserves values across `make configure` re-runs; `gen_envrc` emits the `export` lines with placeholder so fresh `.envrc` includes them and operator is prompted to fill them in |
| Credential consumption | `main.yml` asserts both env vars non-empty at play start; sets Ansible facts; `config.yaml.j2` references facts | Consistent with minio and nexus role patterns; fails fast with clear message if `.envrc` was not sourced |
| `otelcol_minio_endpoint` guard | `main.yml` asserts `otelcol_minio_endpoint` is non-empty before continuing | Prevents OTel Collector starting with a broken exporter config (empty endpoint) when `services.minio` is absent from config YAML |
| Generator addition — group var | Add `elif svc_name == "log_server":` block in `gen_inventory` to emit `otelcol_minio_endpoint` derived from `services.minio.ip/port/tls/fqdn` | No new config YAML fields; existing MinIO config is sufficient |
| Generator addition — envrc | Add `OTELCOL_MINIO_ACCESS_KEY` and `OTELCOL_MINIO_SECRET_KEY` to `_ENVRC_SECRET_VARS` list AND emit `export` lines with `CHANGE_ME` placeholder in `gen_envrc()` | Both changes required; see Credentials in `.envrc` row above |
| Processors | `memory_limiter` → `batch` → `resourcedetection` | memory_limiter prevents OOM on 1 GB LXC; batch buffers for efficient S3 object writes; resource stamps host metadata for log correlation |
| memory_limiter sizing | `limit_mib: 400`, `spike_limit_mib: 100` | Safe ceiling on 1 GB LXC; OTel at rest 50–150 MB; headroom for OS and bursts; at limit: refuses new data; at hard limit: drops data — preferred over OOM kill |
| Batch parameters | `timeout: 60s`, `send_batch_size: 1000` | Time-based flush dominant at homelab log volumes; ~1 S3 object/minute; predictable and inspectable |
| resourcedetection attributes | `system` detector, `host.name` + `os.type` only (both enabled by default) | Safe on unprivileged LXC; hardware-level attributes (`host.cpu.*`, `host.id`) may return empty — not needed for log correlation; verify at deployment |
| Health check extension | `health_check` on `0.0.0.0:13133` | Test gate: confirms full pipeline initialized, not just process started; reachable from controller without SSH |
| Handler ordering | `meta: flush_handlers` called in `main.yml` after `configure.yml` and before `service.yml` | Ensures config-change restart fires before the service start task, preventing double-start on fresh installs |
| Config file | `/etc/otelcol-contrib/config.yaml` | DEB package default confirmed via `.goreleaser.yaml` and `postinstall.sh` in opentelemetry-collector-releases |
| Service management | Systemd unit installed by DEB; Ansible handler restarts on config change | Consistent with all existing roles |
| Splunk HEC exporter | Deferred to Session 2.3 | No Splunk endpoint or HEC token until Session 1.6; stub causes startup errors |
| filelogreceiver | Dropped | Agent-side component — tails local files on source hosts; log server is a central gateway with no local log files to tail |
| RFC 3164 support | Not included | No current source requires it; all sources configurable to RFC 5424; add UDP/RFC 3164 receiver if a future non-configurable device requires it |

---

## Ansible Role Structure

```
ansible/roles/otelcol/
  defaults/main.yml       otelcol_version, otelcol_minio_bucket, otelcol_minio_endpoint (safe empty default),
                          batch timeout/size, memory_limiter limit/spike
  tasks/
    main.yml              assert env vars → orchestrate install → configure → flush_handlers
                          → bucket → service
    install.yml           dpkg-query version check → get_url DEB → dpkg -i (skipped if correct version installed)
    configure.yml         set facts from lookup('env', ...) → template config.yaml.j2
                          → /etc/otelcol-contrib/config.yaml; notifies restart handler
    bucket.yml            delegate_to: localhost, all credential tasks: no_log: true
                          1. mcli alias set homelab-minio-otelcol (MINIO_ENDPOINT + MINIO_ROOT_USER +
                             MINIO_ROOT_PASSWORD) — no_log: true
                          2. mcli mb --ignore-existing homelab-minio-otelcol/otelcol-logs (idempotent by flag)
                          3. mcli admin policy create <policy> via ansible.builtin.shell (pipe required:
                             `echo '...' | mcli admin policy create alias name /dev/stdin`) —
                             failed_when: false (exits non-zero when policy exists, matching bootstrap-minio.sh)
                          4. mcli admin user add (OTELCOL_MINIO_ACCESS_KEY / SECRET_KEY) — no_log: true;
                             failed_when: false (exits non-zero when user exists — idempotent by guard)
                          5. mcli admin policy attach — failed_when: false
    service.yml           systemd enable + start otelcol-contrib
  templates/
    config.yaml.j2        OTel Collector config (receivers, processors, exporters, service pipeline)
  handlers/main.yml       Restart otelcol-contrib service
```

Playbook: `ansible/playbooks/log-server-setup.yml`

---

## Pipeline

```
syslog receiver (TCP 1514, RFC 5424)
    └── memory_limiter (limit: 400 MiB, spike: 100 MiB)
        └── batch (timeout: 60s, size: 1000)
            └── resourcedetection (system: host.name, os.type)
                └── awss3exporter → MinIO otelcol-logs bucket
                    s3_partition_format: year=%Y/month=%m/day=%d/hour=%H/minute=%M
                    # Note: verify exact key name at role-writing time — first research confirmed
                    # s3_partition_format with this default from the README; cross-check against
                    # installed otelcol-contrib version (some older versions use s3_prefix for static prefixes)
                    s3_force_path_style: true
                    endpoint: {{ otelcol_minio_endpoint }}

extensions:
  health_check: 0.0.0.0:13133
```

Session 2.3 adds a fanout: `[awss3exporter, splunk_hec/logs]` in the same pipeline.

---

## Generator Changes

### 1. `_ENVRC_SECRET_VARS` + `gen_envrc()` (lines ~143 and ~845 in `generate-configs.py`)

Two changes required — both needed for correct `.envrc` handling:

**a) `_ENVRC_SECRET_VARS`** — preserves values across `make configure` re-runs:

```python
_ENVRC_SECRET_VARS = [
    ...existing entries...
    "OTELCOL_MINIO_ACCESS_KEY",
    "OTELCOL_MINIO_SECRET_KEY",
]
```

**b) `gen_envrc()`** — emit placeholder lines so fresh `.envrc` includes the vars and
operator is prompted to fill them in (append after the Nexus section):

```python
        # OTel Collector credentials — used by Ansible log-server-setup.yml playbook
        # Generate via: mcli admin user add <alias> <access-key> <secret-key>
        export OTELCOL_MINIO_ACCESS_KEY="{CHANGE_ME}"  # write-scoped key for otelcol-logs bucket
        export OTELCOL_MINIO_SECRET_KEY="{CHANGE_ME}"  # write-scoped secret
```

### 2. `gen_inventory` — `log_server` group vars block

Within the `for svc_name, svc in svcs.items()` / `if "ip" in svc:` loop, add after the
`elif svc_name == "nexus":` block:

```python
elif svc_name == "log_server":
    minio_svc = svcs.get("minio", {})
    minio_tls = minio_svc.get("tls", False)
    minio_fqdn = minio_svc.get("fqdn", "")
    minio_ip = _strip_prefix(minio_svc.get("ip", ""))
    minio_port = minio_svc.get("port", 9000)
    if minio_tls and minio_fqdn:
        otelcol_endpoint = f"https://{minio_fqdn}:{minio_port}"
    elif minio_ip:
        otelcol_endpoint = f"http://{minio_ip}:{minio_port}"
    else:
        otelcol_endpoint = ""
    if otelcol_endpoint:
        lines.append(f"      vars:")
        lines.append(f"        otelcol_minio_endpoint: \"{otelcol_endpoint}\"")
    # NOTE: do NOT append "      hosts:" here — the outer flat-service loop appends
    # it unconditionally at line 666 after this elif chain. Adding it here produces
    # a duplicate YAML key.
```

No new `config/<env>.yml` fields required — derives from existing `services.minio` config.

---

## `main.tf` Side Effect

Update the comment on the `log_server` module block: `port 5140` → `port 1514`.
Comment-only change; no Terraform resource impact.

---

## Pre-Run Operator Checklist

Before running the playbook:
1. Confirm `services.log_server` is present in `config/<env>.yml` with a valid `ip` field — without this, `make configure` will not emit the `log_server` inventory group and the playbook will have no hosts to target
2. Decide values for `OTELCOL_MINIO_ACCESS_KEY` and `OTELCOL_MINIO_SECRET_KEY` (arbitrary strings — role creates the MinIO user with these exact credentials)
3. Fill in both `CHANGE_ME` placeholders in `.envrc`, run `direnv allow`
4. Confirm `MINIO_ENDPOINT`, `MINIO_ROOT_USER`, and `MINIO_ROOT_PASSWORD` are set in `.envrc` — `bucket.yml` uses them to create the `homelab-minio-otelcol` mcli alias

---

## Test Gate

```bash
# 1–2: Run on log-server LXC via sandbox-ssh
sandbox-ssh <log-server-ip> "systemctl is-active otelcol-contrib"
sandbox-ssh <log-server-ip> "ss -tlnp | grep 1514"

# 3: Run on log-server LXC — port 13133 is not in Squid Safe_ports so curl from the
#    controller would be denied; run via sandbox-ssh instead
sandbox-ssh <log-server-ip> "curl -s http://localhost:13133"   # returns HTTP 200
# Optional: add port 13133 to squid.conf Safe_ports + make build to enable
#           direct controller-side curl (operator step, requires container rebuild)

# 4: Run on controller — send valid RFC 5424 message, verify object lands in MinIO
#    (wait up to 60s for batch timeout to flush)
echo "<14>1 $(date -u +"%Y-%m-%dT%H:%M:%SZ") testhost test - - - otelcol pipeline check" \
  | nc <log-server-ip> 1514
sleep 65
mcli ls homelab-minio-otelcol/otelcol-logs/   # alias created by bucket.yml
```

---

## Open Items (deferred, not forgotten)

| Item | Deferred to |
|---|---|
| Splunk HEC exporter — fanout pipeline | Session 2.3: OTel → Splunk HEC end-to-end |
| Source-side configuration (OPNsense, rsyslog, DNSdist) | Session 2.1 / 2.2 |
| MinIO bucket lifecycle policy (365-day expiry) | Session 2.3 or standalone Day-2 ops: `mcli ilm add --expiry-days 365 local/otelcol-logs` |
| APT repo verification (`packages.opentelemetry.io`) | Verify at role-writing time; prefer APT over DEB download if confirmed stable |
| **DEB download requires internet on target LXC** — `install.yml` fetches from GitHub directly; MGMT VLAN hosts have no outbound internet in production; fix: upload DEB to Nexus raw hosted repo and point `get_url` url at Nexus | Session 2 — implement alongside Nexus raw repo (also needed for Splunk) |
| TF-managed MinIO for log storage | Post-GitLab migration decision |
| resourcedetection attribute verification on unprivileged LXC | Verify at deployment — fall back to `host.name` + `os.type` only if others fail |

---

## Ready for Planning

Design is complete. Hand to `/ansible-deploy` with this design record as input.

**What to build:**
Ansible role `otelcol` + playbook `log-server-setup.yml`. Role installs `otelcol-contrib` DEB
(idempotent version check), configures the syslog → MinIO pipeline via Jinja2 template,
provisions the MinIO `otelcol-logs` bucket and write-only IAM user via `mcli` delegated to the
controller, and manages the systemd service with correct handler flush ordering. Generator
changes: `OTELCOL_MINIO_*` added to `_ENVRC_SECRET_VARS`; `otelcol_minio_endpoint` emitted
into `log_server` group vars. `main.tf` comment updated from port 5140 → 1514.
