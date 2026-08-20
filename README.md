# homelab-proxmox-harness

A private cloud security platform built on Proxmox VE. The stack spans infrastructure-as-code, a two-tier internal PKI, authoritative DNS with encrypted transport, an artifact supply chain mirror, centralized log aggregation, and a Splunk SIEM — wired together as a trust chain where each layer depends on the one below it.

Operations are handled by a **design-record-driven AI agent** built on Claude Code: the operator agrees a design record, the agent executes it autonomously in an expendable sandbox, and behavioral verification gates every result. The security boundary on the agent itself is IAM-first — pool-scoped credentials, credential separation, and a formally modeled threat surface — the same security engineering principles applied to the infrastructure are applied to the agent operating it.

**Three pillars:** security infrastructure · infrastructure-as-code · AI-assisted operations

---

## Platform Architecture

Each service layer depends only on what sits below it in the trust chain:

```
┌──────────────────────────────────────────────────────┐
│  AI Operations Layer                                  │
│  Design record → autonomous execution → verification  │
│  IAM scoping · credential separation · sandbox pool   │
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

- **Component architecture** — one `components/<name>/` directory owns each service vertically (manifest, Ansible playbook + roles, behavioral verify, state collector, config fragment); the core is generic and discovers components, so adding a service touches no central file. A gitignored `components.local/` overlay hosts private components through the same code path. Full design: [`docs/design/component-architecture.md`](docs/design/component-architecture.md)
- **Terraform (bpg/proxmox v0.99+)** — a generic root module (`for_each` over a typed services map) built on three primitives: `proxmox-vm` (cloud-init), `proxmox-lxc` (unprivileged Debian containers), `proxmox-network` (Linux bridges)
- **Ansible** — component-owned roles, idempotent and vendor-repo-sourced (not distro packages); shared baseline roles for trust and logging
- **MinIO** — self-hosted S3 for Terraform remote state; per-environment buckets with scoped IAM keys
- **Centralized config** — `config/<env>.yml` is the single source of truth; component manifests define each service's schema; `make configure` generates tfvars, Ansible inventory, `ansible.cfg`, and `.envrc` from one file
- **Two environments** — sandbox and production with physically separate credentials; production applies are blocked by design (the production token never exists on the agent host)

A service is enabled by its presence in config — phased rollout and clean teardown fall out of the discovery model.

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

### Design-Record-Driven Operations

The agent runs on a dedicated controller host with sandbox-scoped credentials. Work
follows a deliberately light loop:

1. **Design** (`/design`) — a one-decision-at-a-time exploration ending in a committed
   design record; operator agreement on the record is the go signal.
2. **Execute** (`/free-run` or directly) — the agent builds against the record in the
   expendable sandbox: journaled decisions, per-slice commits, failures captured as
   lessons rather than halts.
3. **Verify** — every component ships a behavioral `verify.sh` (`make verify-all` is the
   hard gate); `/sanity-sweep` adds a judgment-based Tier-2 read of live state.
4. **Production** — the agent only ever produces a plan file plus `/handoff` notes; the
   operator reviews and applies.

A single reviewer agent (**tf-reviewer**, `/review`) provides an on-demand
`APPROVE`/`WARN`/`BLOCK` pass over Terraform, Ansible, and component changes.

### Security Boundary on the AI

The same engineering discipline applied to the infrastructure is applied to the agent operating it:

| Control | Mechanism | What it prevents |
|---|---|---|
| **IAM scoping** | Proxmox token ACL limited to `/pool/sandbox`; MinIO key scoped to `tfstate-sandbox` bucket; `privsep=1` blocks privilege escalation | Claude affecting production state or Proxmox IAM |
| **Credential separation** | Production credentials never exist on the agent host | Production apply fails at authentication even if all other controls are bypassed |
| **Network segmentation** | The controller host routes to sandbox segments only (operator-managed) | Claude reaching production infrastructure |
| **Workflow controls** | Plan-file-gated applies, push denied to the agent, operator pre-push review | Unreviewed changes or history leaving the machine |

Full analysis in [`docs/threat-model.md`](docs/threat-model.md) — including what the model *does not* protect against and residual risks.

### Skills (Slash Commands)

| Command | What it does |
|---|---|
| `/design <idea>` | Explore architecture decisions — one decision at a time, ends in a design record |
| `/free-run` | Execute an agreed design record autonomously — journal, per-slice commits, verify gates |
| `/review [files]` | Single-pass code review via tf-reviewer — `APPROVE` / `WARN` / `BLOCK` |
| `/sanity-sweep` | Tier-2 judgment sweep over live deployed state — record-only findings |
| `/day2-ops` | Resize, snapshot, or reconfigure existing VMs/LXCs |
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

Requires: Proxmox VE 8.x, Terraform, Ansible, direnv on a controller host that can reach the sandbox network.

```bash
git clone <this-repo> && cd homelab-proxmox-harness
cp config/sandbox.yml.example config/sandbox.yml
# Edit config/sandbox.yml — Proxmox nodes, networks, service blocks, agent SSH facts
make configure          # generates tfvars, inventory, ansible.cfg, .envrc
# Fill in .envrc: Proxmox token, MinIO keys (see docs/proxmox-iam.md)
direnv allow
make init && make plan  # initialize state backend, plan infrastructure
make apply              # apply plan file
make ansible-<name>     # deploy a component (e.g. make ansible-pki)
make verify-all         # behavioral verify of every enabled component
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
- [`docs/network-policy.md`](docs/network-policy.md) — network boundary in the controller-host model

---

## Roadmap

Active development priorities as of Summer 2026:

1. **Detection Engineering** — Firewall log ingestion and auth syslog from managed hosts; detection rules against DNS, network, and auth data sources; attack simulation scripts for rule validation

2. **AI-Agent Abuse Defenses** — Evolving the harness from free-run lessons: reinstating the staged-secrets check as a git pre-commit hook, auditing agent tool scope, and documenting adversarial test cases against the design-record workflow

3. **Splunk Hackathon** — Packaging the OTel → Splunk pipeline, AI Toolkit integration, and detection rule set as a reproducible reference architecture for the hackathon submission

4. **Management VLAN** — Isolating DNS, PKI, MinIO, and management interfaces onto a dedicated segment with strict ingress/egress policy

Further out: Keycloak (OIDC/SSO), GitLab (self-hosted CI/CD + GitOps), Prometheus + Grafana, Wazuh EDR, DNSSEC + RPZ threat intel blocklists. See [`docs/vision.md`](docs/vision.md).

---

## License

MIT
