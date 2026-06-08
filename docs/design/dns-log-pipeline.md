# Design: DNS Query Log Pipeline

## Goal

Route per-query DNS telemetry from the DNS proxy host into the OTel Collector log pipeline,
providing structured DNS data for raw retention (S3) and downstream SIEM ingestion. Replaces
a prior design that was invalidated by live testing — the original path was architecturally
incompatible and produced no data.

---

## Background: What Was Invalidated

The prior design used dns-collector's `opentelemetry` output to forward DNS data to the OTel
Collector via OTLP/gRPC. Live testing confirmed two compounding failures:

1. **Signal type mismatch.** dns-collector's `opentelemetry` output sends OTel distributed
   traces (not logs). The `logs/dns` OTel pipeline silently drops traces.

2. **Input incompatibility.** The `opentelemetry` output is designed for PowerDNS protobuf
   input (which carries trace IDs for span correlation). With dnstap input, the OTel worker
   self-terminates on the first message. This is a code-level constraint — not a
   configuration issue on either side.

An alternative (switching DNSdist to protobuf output) was considered but rejected: protobuf
enables richer trace context (span correlation, trace IDs), but this has no value for a
Splunk SIEM use case where the goal is per-query log records, not distributed tracing.

---

## Design Decisions

| # | Decision | Choice | Rationale |
|---|---|---|---|
| 1 | DNSdist emission format | Stay on dnstap — no DNSdist changes | dnstap→dns-collector link confirmed working; protobuf gains trace IDs with no SIEM value; DNSdist restart avoided |
| 2 | dns-collector output | `syslog` TCP, RFC 5424, `mode: json`, dedicated port | Stable output compatible with dnstap input; JSON body carries all DNS fields needed for SIEM; RFC 5424 consistent with firewall syslog path |
| 3 | OTel Collector receiver | Add `syslog/dns` receiver on dedicated port (RFC 5424); replace `otlp` receiver in `logs/dns` pipeline | Consistent with existing `logs/firewall` pattern; `otlp` receiver removed (nothing else uses it) |
| 4 | Source identification | `com.splunk.source: "dnstap:dns-collector"` unchanged | Origin label is more useful than transport label for Splunk SIEM queries |
| 5 | JSON body parsing in OTel | Deferred — raw JSON body passed through | Splunk handles JSON body at ingest; OTel-level json_parser adds complexity with no near-term benefit |

---

## Data Flow

```
DNSdist
  │  dnstap TCP (unchanged)
  ▼
dns-collector
  │  syslog TCP / RFC 5424 / JSON body
  ▼
OTel Collector — syslog/dns receiver
  │  logs/dns pipeline
  │  processors: memory_limiter → batch → resourcedetection → resource/dns
  ▼
S3 (MinIO) — raw retention
  │  (future)
  ▼
Splunk HEC
```

---

## Component Summary

| Component | Change | Notes |
|---|---|---|
| DNSdist | None | dnstap output unchanged |
| dns-collector | Output: `opentelemetry` → `syslog` TCP, RFC 5424, JSON | `dns_collector` Ansible role — `config.yml.j2` only |
| OTel Collector | Add `syslog/dns` receiver; update `logs/dns` pipeline; remove `otlp` receiver | `otelcol` Ansible role — `config.yaml.j2` only |
| OTel `resource/dns` processor | `com.splunk.source` stays `"dnstap:dns-collector"` | No change |

---

## OTel Config Shape (delta from current)

```yaml
receivers:
  syslog:               # existing — firewall, unchanged
    tcp:
      listen_address: "0.0.0.0:1514"
    protocol: rfc5424
  syslog/dns:           # new — replaces otlp receiver
    tcp:
      listen_address: "0.0.0.0:{{ otelcol_dns_syslog_port }}"
    protocol: rfc5424
  # otlp receiver removed

service:
  pipelines:
    logs/firewall:      # unchanged
      receivers: [syslog]
      ...
    logs/dns:
      receivers: [syslog/dns]   # was: [otlp]
      processors: [memory_limiter, batch, resourcedetection, resource/dns]
      exporters: [awss3]
```

---

## dns-collector Config Shape (delta from current)

```yaml
pipelines:
  - name: "tap"
    dnstap:                       # unchanged
      listen-ip: "{{ dns_collector_dnstap_listen_ip }}"
      listen-port: {{ dns_collector_dnstap_listen_port }}
      tls-support: false
    routing-policy:
      forward: ["syslog-out"]

  - name: "syslog-out"            # replaces opentelemetry output
    syslogclient:
      transport: tcp
      address: "{{ dns_collector_syslog_endpoint }}"
      port: {{ dns_collector_syslog_port }}
      formatter: rfc5424
      mode: json
```

---

## Ansible Role Impact

| Role | Files changed | New variables |
|---|---|---|
| `dns_collector` | `templates/config.yml.j2`, `defaults/main.yml` | `dns_collector_syslog_endpoint`, `dns_collector_syslog_port` |
| `otelcol` | `templates/config.yaml.j2`, `defaults/main.yml` | `otelcol_dns_syslog_port` |

No new roles. No Terraform changes. No DNSdist playbook changes.

---

## Open Items (deferred, not forgotten)

| Item | Deferred to |
|---|---|
| `json_parser` transform in OTel pipeline | When MinIO direct querying (DuckDB/Athena) becomes a use case — promotes JSON body fields to structured log attributes |
| Verify syslog port is free on log server | Pre-implementation check before Ansible run |
| Verify network path: DNS proxy host → log server on syslog port | Pre-implementation — confirm no firewall rule needed |
| `com.splunk.index` on DNS pipeline | Session 2.3 (HEC exporter + index topology) |

---

## Ready for Planning

Design is complete. Two role edits required — no new infrastructure.

Run `/infra-plan` is not needed. Run `/ansible-deploy` with this document as input:
- `dns_collector` role: swap output block in `config.yml.j2`, add two new defaults
- `otelcol` role: swap receiver in `config.yaml.j2`, add one new default, remove `otlp` receiver
