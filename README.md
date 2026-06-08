# homelab-proxmox-harness

A private cloud security platform built on Proxmox VE. The stack spans infrastructure-as-code, a two-tier internal PKI, authoritative DNS with encrypted transport, an artifact supply chain mirror, centralized log aggregation, and a Splunk SIEM — wired together as a trust chain where each layer depends on the one below it.

Operations are handled by a **human-in-the-loop AI pipeline** (Planner → Generator → Evaluator) built on Claude Code, with a formally modeled security boundary on the AI itself: network isolation, IAM scoping, and hook-based enforcement — the same security engineering principles applied to the infrastructure are applied to the agent operating it.

**Three pillars:** security infrastructure · infrastructure-as-code · AI-assisted operations

---

## Platform Architecture

Each service layer depends only on what sits below it in the trust chain:

```
┌──────────────────────────────────────────────────────┐
│  AI Operations Layer                                  │
│  PGE Pipeline (plan → generate → review → apply)     │
│  Squid proxy isolation · IAM scoping · Hook gates     │
└──────────────────┬───────────────────────────────────┘
                   │ provisions & configures
┌──────────────────▼───────────────────────────────────┐
│  Compute                                              │
│  Proxmox VE · Terraform (bpg/proxmox) · Ansible      │
│  MinIO (S3 state) · sandbox + production isolation    │
└──────────────────┬───────────────────────────────────┘
                   │ base trust for all services
┌──────────────────▼───────────────────────────────────┐
│  PKI  (step-ca, two-tier)                             │
│  Offline root CA VM  +  Always-on issuing CA (ACME)  │
│  All services receive TLS certs from internal CA      │
└──────────────────┬───────────────────────────────────┘
                   │ resolves internal services
┌──────────────────▼───────────────────────────────────┐
│  DNS  (PowerDNS Auth + Recursor + DNSdist)            │
│  Authoritative · Recursive · DoT/DoH-ready            │
│  Per-host DNS query telemetry via dns-collector       │
└──────────────────┬───────────────────────────────────┘
                   │ serves packages to all deployments
┌──────────────────▼───────────────────────────────────┐
│  Artifact Supply Chain  (Nexus CE)                    │
│  APT proxy · OCI registry · Terraform provider mirror │
│  Offline-capable: no internet dependency post-setup   │
└──────────────────┬───────────────────────────────────┘
                   │ receives syslog from all layers
┌──────────────────▼───────────────────────────────────┐
│  Observability                                        │
│  OTel Collector Contrib gateway (all managed hosts)   │
│  MinIO S3 archive  +  Splunk HEC exporter             │
└──────────────────┬───────────────────────────────────┘
                   │ detection + AI analysis
┌──────────────────▼───────────────────────────────────┐
│  SIEM  (Splunk Enterprise)                            │
│  HEC ingest · AI Toolkit · MCP Server integration     │
│  DNS query logs · auth events · Proxmox API audit     │
└──────────────────────────────────────────────────────┘
```

---

## What's Built

### Infrastructure Foundation

- **Terraform (bpg/proxmox v0.99+)** — provisions Proxmox VMs and LXCs via three reusable modules: `proxmox-vm` (cloud-init), `proxmox-lxc` (unprivileged Debian containers), `proxmox-network` (Linux bridges)
- **Ansible (13 roles)** — configures all provisioned hosts; roles are idempotent and vendor-repo-sourced (not distro packages)
- **MinIO** — self-hosted S3 for Terraform remote state; per-environment buckets with scoped IAM keys
- **Centralized config** — `config/<env>.yml` is the single source of truth; `make configure` generates tfvars, Ansible inventory, Squid allowlist, and `.envrc` from one file
- **Two environments** — sandbox and production with physically separate credentials; production applies are blocked by design (the production token is never in the dev container)

Each service is deployment-gated via a Terraform feature flag (`enable_pki`, `enable_dns`, etc.), allowing phased rollout and clean teardown.

### PKI — Two-Tier Internal CA

- **Offline root CA** (VM, starts on-demand): generates self-signed root cert with step-cli; powered off except during signing operations
- **Issuing CA** (always-on LXC): runs step-ca with ACME + JWK provisioners; issues certificates for DNS, Nexus, Splunk, and Ansible-managed TLS endpoints
- Root cert distributed to system trust stores via the `common` Ansible role — new hosts trust internal services out of the box
- Designed for ACME-automated renewal; no manual cert management

### DNS — Full Resolver Stack

- **PowerDNS Authoritative** (SQLite/WAL backend, loopback-only) — manages the internal zone; API key-authenticated
- **PowerDNS Recursor** — recursive resolver; forwards to Auth for internal zones, upstream for everything else
- **DNSdist** — client-facing frontend; plain DNS port 53, DoT port 853, DoH port 443 (TLS via step-ca ACME); ACL-controlled query sources
- **dns-collector** (dmachard/dns-collector) — lightweight query tap deployed per-host; forwards DNS telemetry to OTel Collector over syslog; provides per-host DNS visibility in Splunk

### Artifact Supply Chain — Nexus CE

- APT proxy mirrors Debian package repos — all Ansible deployments install packages through Nexus; no managed host needs direct internet access after bootstrap
- OCI registry for container images
- Terraform provider registry — pins provider versions offline
- Raw hosted repositories for custom artifacts (e.g. Splunk app bundles, custom binaries)
- nginx reverse proxy with TLS from internal CA

### Observability — OTel Collector Gateway

- **otelcol-contrib** deployed as a central log gateway; receives syslog (RFC 5424, TCP) from all managed hosts on port 1514
- Memory limiter + batch processor + resourcedetection processors
- Dual export: MinIO S3 bucket (`otelcol-logs`, 365-day lifecycle) for long-term archive, Splunk HEC for real-time SIEM ingest
- Log sources: DNS query logs (dns-collector), host auth events (rsyslog), Proxmox API audit logs, OPNsense firewall logs

### SIEM — Splunk Enterprise

- Single-instance Splunk Enterprise (Ubuntu 24.04, sized to Splunk minimums)
- HEC token-authenticated ingest from OTel Collector
- RBAC configured: dedicated MCP Server user with `mcp_tool_execute` capability, scoped to AI toolkit operations only
- Splunk AI Toolkit and MCP Server installed — enables AI-assisted search and detection authoring
- Splunk MCP Server enables Claude Code to query Splunk directly during detection engineering sessions

---

## AI Operations Harness

### Planner-Generator-Evaluator (PGE) Architecture

Infrastructure changes move through three purpose-scoped agent roles with human approval gates between each stage:

| Role | Model | Responsibility |
|---|---|---|
| **iac-planner** | Claude Opus | Reads existing code and docs, researches the change, produces a structured plan — no code written |
| **iac-generator** | Claude Sonnet | Translates the *approved* plan into Terraform/Ansible code — does not plan or review |
| **tf-reviewer** | Claude Sonnet | Reviews generated code for security, correctness, and bpg/proxmox conventions — returns `APPROVE` / `WARN` / `BLOCK` |

No agent can skip a gate or grant itself permission to proceed. The operator approves the plan before code is generated; the operator reviews the verdict before any apply runs.

### Security Boundary on the AI

The same engineering discipline applied to the infrastructure is applied to the agent operating it:

| Control | Mechanism | What it prevents |
|---|---|---|
| **Network isolation** | Dev container on `internal:true` Docker network; all traffic through Squid forward proxy (allowlist: sandbox VLAN, MinIO, GitHub releases, Terraform registry) | Claude reaching production infrastructure or arbitrary internet |
| **IAM scoping** | Proxmox token ACL limited to `/pool/sandbox`; MinIO key scoped to `tfstate-sandbox` bucket; `privsep=1` blocks privilege escalation | Claude affecting production state or Proxmox IAM |
| **PreToolUse hooks** | Block `terraform destroy`, `state rm`, `force-unlock` before execution — independent of any Claude instruction | Accidental or injected destructive operations |
| **Credential separation** | Production Proxmox token is never provisioned in the dev container | Production apply fails at authentication even if all other controls are bypassed |

Full analysis in [`docs/threat-model.md`](docs/threat-model.md) — including what the model *does not* protect against and residual risks.

### Skills (Slash Commands)

| Command | What it does |
|---|---|
| `/design <idea>` | Explore architecture decisions before planning — one decision at a time, no code |
| `/infra-plan <description>` | Structured infrastructure plan via iac-planner (Opus) |
| `/generate` | Write Terraform/Ansible from an approved plan via iac-generator |
| `/review [files]` | Single-pass code review via tf-reviewer — `APPROVE` / `WARN` / `BLOCK` |
| `/polish [code\|plan\|design]` | Iterative review-fix loop until `APPROVE` — all cycles run in subagents |
| `/tf-deploy <description>` | Full Terraform pipeline: design → plan → generate → review → apply |
| `/ansible-deploy <description>` | Full Ansible pipeline: design → plan → generate → review → run |
| `/ansible-run` | Pre-flight + run + verify for already-reviewed Ansible code |
| `/assess <scope>` | Structured project assessment — surfaces assumptions before remediation |
| `/handoff` | Package a production plan for operator handoff |
| `/retro` | Session retrospective — surfaces prompting lessons and skill lifecycle |

---

## Detection Engineering

The observability stack is designed to generate the signal needed to write and validate detection rules:

- **DNS query telemetry** — dns-collector on each host feeds all queries through OTel into Splunk; unusual query patterns, C2 beaconing signatures, and DNS exfiltration attempts are detectable
- **Auth event logging** — rsyslog on managed hosts feeds auth events (SSH logins, sudo, PAM) to OTel Collector
- **Proxmox API audit trail** — API request logs surface unexpected resource creation, token use anomalies, and lateral movement attempts
- **Firewall logs** — OPNsense forwards syslog to OTel Collector; network-level visibility across VLANs

**Attack simulation** (active development): automated scripts target the specific data sources ingested — DNS queries, auth events, API calls — to generate known-bad patterns. Detection rules are validated against simulated attacks before production deployment.

**Splunk AI Toolkit + MCP Server** — Claude Code can query Splunk directly during detection sessions, correlating log sources and iterating on SPL queries in the same conversation as infrastructure changes.

---

## Quick Start

Requires: Proxmox VE 8.x, Docker + Dev Containers, direnv.

```bash
git clone <this-repo> && cd homelab-proxmox-harness
cp config/sandbox.yml.example config/sandbox.yml
# Edit config/sandbox.yml — Proxmox node, network CIDRs, service flags
make configure          # generates tfvars, inventory, Squid allowlist, .envrc
# Fill in .envrc: Proxmox token, MinIO keys (see docs/proxmox-iam.md)
direnv allow
make build              # rebuild Squid image with updated allowlist
# Reopen in dev container (VS Code: Ctrl+Shift+P → "Dev Containers: Reopen in Container")
make verify-isolation   # confirm network isolation
make init && make plan  # initialize state backend, plan infrastructure
make apply              # apply plan file
```

Full walkthrough: [`docs/guides/deployment-guide.md`](docs/guides/deployment-guide.md)

---

## Documentation

**Design records** — decision journals from architecture sessions, capturing what was decided and why:

| Doc | Subject |
|---|---|
| [`dns-design.md`](docs/design/dns-design.md) | PowerDNS stack architecture |
| [`otelcol-design.md`](docs/design/otelcol-design.md) | OTel Collector gateway |
| [`artifact-server-design.md`](docs/design/artifact-server-design.md) | Nexus CE selection and layout |
| [`splunk-hackathon-design.md`](docs/design/splunk-hackathon-design.md) | Splunk AI Toolkit integration |
| [`dns-log-pipeline.md`](docs/design/dns-log-pipeline.md) | DNS telemetry pipeline |
| [`mgmt-vlan-design.md`](docs/design/mgmt-vlan-design.md) | Management VLAN segmentation |
| *(+ 9 more in `docs/design/`)* | |

**Operational guides:**

| Doc | Contents |
|---|---|
| [`deployment-guide.md`](docs/guides/deployment-guide.md) | Phased sandbox deployment (5 phases) |
| [`pki-setup.md`](docs/guides/pki-setup.md) | Two-tier CA initialization and cert lifecycle |
| [`splunk-setup.md`](docs/guides/splunk-setup.md) | Splunk Enterprise and OTel wiring |
| [`trust-root-ca.md`](docs/guides/trust-root-ca.md) | Installing internal root CA on workstations |
| [`minio-setup.md`](docs/guides/minio-setup.md) | MinIO bootstrap and bucket IAM |

**Architecture docs:**

- [`docs/proxmox-iam.md`](docs/proxmox-iam.md) — API token design, ACL paths, role definitions
- [`docs/threat-model.md`](docs/threat-model.md) — Isolation model: what it covers, what it doesn't, residual risks
- [`docs/network-policy.md`](docs/network-policy.md) — Squid allowlist, SSH tunnel architecture

---

## Roadmap

Active development priorities as of Summer 2026:

1. **Detection Engineering** — Firewall log ingestion and auth syslog from managed hosts; detection rules against DNS, network, and auth data sources; attack simulation scripts for rule validation

2. **AI-Agent Abuse Defenses** — Tightening PreToolUse hook coverage, auditing agent tool scope, and documenting adversarial test cases against the PGE harness

3. **Splunk Hackathon** — Packaging the OTel → Splunk pipeline, AI Toolkit integration, and detection rule set as a reproducible reference architecture for the hackathon submission

4. **Management VLAN** — Isolating DNS, PKI, MinIO, and management interfaces onto a dedicated segment with strict ingress/egress policy

Further out: Keycloak (OIDC/SSO), GitLab (self-hosted CI/CD + GitOps), Prometheus + Grafana, Wazuh EDR, DNSSEC + RPZ threat intel blocklists. See [`docs/vision.md`](docs/vision.md).

---

## License

MIT
