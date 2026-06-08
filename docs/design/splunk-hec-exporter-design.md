# Design: OTel → Splunk HEC Exporter (Session 2.3)

## Goal

Add the Splunk HEC exporter to the OTel Collector so DNS and firewall log pipelines deliver
events into Splunk in real time. This completes the pipeline segment required before Phase 3
(MCP end-to-end demo): log-source → dns-collector/firewall → OTel Collector → Splunk.

## Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Exporter topology | Fanout: splunkhec alongside awss3 | Both exporters healthy; S3 for long-term retention, HEC for real-time search |
| Index topology | Single shared index (`homelab-logs`) | One operator, dev license, same retention — sourcetype already differentiates DNS from firewall |
| `com.splunk.index` placement | Resource processor (both pipelines) | Explicit; colocated with existing sourcetype/source stamps; visible from the template |
| TLS for HEC | None (HTTP) | `otelcol_splunk_hec_url` resolves to `http://...:8088` — no TLS config block needed |
| Token handling | Ansible fact embedded in config.yaml.j2 | `otelcol-contrib validate` runs before the env file is written; `${ENV_VAR}` expansion fails at validate time; embed via fact with `no_log: true` on template task |
| Pipeline validation | Manual SPL query post-deploy | Pipeline already confirmed (data to MinIO); HEC errors surface in `journalctl -u otelcol-contrib`; one SPL search verifies end-to-end |

## Changes Required

### `ansible/roles/otelcol/templates/config.yaml.j2`

1. Add `com.splunk.index: homelab-logs` to both `resource/firewall` and `resource/dns` processor attribute lists
2. Add `splunkhec` exporter block:
   ```yaml
   splunkhec:
     endpoint: "{{ otelcol_splunk_hec_url }}"
     token: "{{ otelcol_splunk_hec_token }}"
     log_data_enabled: true
   ```
3. Add `splunkhec` to the `exporters:` list in both `logs/firewall` and `logs/dns` pipelines

### `ansible/roles/otelcol/tasks/main.yml`

Add assert + set_fact block for the HEC token (following the existing MinIO credential pattern):
```yaml
- name: Assert SPLUNK_HEC_TOKEN is set
  ansible.builtin.assert:
    that:
      - lookup('env', 'SPLUNK_HEC_TOKEN') | length > 0
    fail_msg: "SPLUNK_HEC_TOKEN is not set. Add it to .envrc and run: source .envrc"

- name: Set otelcol Splunk HEC token as fact
  ansible.builtin.set_fact:
    otelcol_splunk_hec_token: "{{ lookup('env', 'SPLUNK_HEC_TOKEN') }}"
  no_log: true
```

### `ansible/roles/otelcol/tasks/configure.yml`

Add `no_log: true` to the "Template OTel Collector config" task (config.yaml.j2 will now contain the HEC token value).

### `ansible/roles/otelcol/defaults/main.yml`

Add `otelcol_splunk_hec_url: ""` with a note that it is overridden by generate-configs.py for the log_server group.

## Component Summary

| Component | Location | Change |
|---|---|---|
| OTel Collector | log-server LXC | Config: add splunkhec exporter, stamp com.splunk.index |
| Splunk | Splunk VM, port 8088 (HEC) | Pre-condition: `homelab-logs` index must exist before first event arrives |
| Ansible otelcol role | `ansible/roles/otelcol/` | template, tasks/main.yml, tasks/configure.yml, defaults/main.yml |

## Operator Pre-condition

Create the `homelab-logs` index in Splunk before running the playbook:
```
splunk add index homelab-logs
```
Or via Splunk Web: Settings → Indexes → New Index.

## Post-Deploy Validation

```spl
index=homelab-logs | head 10
```

Expected: events from both `sourcetype=dns:query` and `sourcetype=network:firewall`.
If empty after a few minutes, check: `journalctl -u otelcol-contrib -n 50` on log-server.

## Open Items (deferred, not forgotten)

- `com.splunk.source` label on `resource/dns` reads `dnstap:dns-collector` (logical origin) — intentional, confirmed in commit `20b55ca`. No change needed.
- Separate indexes (`homelab-dns`, `homelab-firewall`) — extension path if RBAC or per-source retention is needed later. Requires only a resource processor change + Splunk index creation.

## Ready for Planning

Design complete. Hand to `/infra-plan` or `/generate` directly — all file paths and change scope are specified above.
