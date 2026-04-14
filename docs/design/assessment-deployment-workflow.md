# Fresh Deployment Assessment — Findings & Remediation Strategy

_Assessment date: 2026-04-10_

---

## 1. What We Found

### 1.1 Service-Level Dependency Map

The four services are not circularly dependent. They form a directed chain with one
re-entrant pass (TLS upgrade). The "circular" feeling comes from three specific knots.

```
MinIO (HTTP) ──► TF apply ──► Nexus ──► DNS ──► PKI ──► TLS upgrade (MinIO + Nexus)
     ▲                                    │
     └──────── TF state backend ──────────┘
```

**Knot A — MINIO_ENDPOINT FQDN deadlock (real, unresolved today)**

When `minio.tls: true`, the generator emits:
```
MINIO_ENDPOINT="https://minio.lab.example.com:9000"
```
This FQDN requires DNS. DNS is deployed after Terraform. Terraform needs
`MINIO_ENDPOINT` to init its backend. True deadlock if TLS is enabled from the start.

_Resolution: generator always emits IP-based `MINIO_ENDPOINT` (`https://<ip>:9000`).
MinIO TLS cert includes the IP as a SAN so TLS validates against the IP._

**Knot B — bootstrap-minio.sh TLS (not an actual problem)**

`bootstrap-minio.sh` runs in Phase 1 when MinIO is plain HTTP. No TLS, no cert
validation, no issue. The script is fine as written.

**Knot C — Managed host DNS resolution gap (real, unresolved today)**

Cert issuance on managed hosts runs:
```
step ca certificate ... --ca-url https://ca.lab.example.com
```
The managed host must resolve `ca.lab.example.com`. No Ansible role configures the
DNS resolver on managed hosts. With DHCP-assigned DNS (router/ISP), internal FQDNs
never resolve.

_Resolution: manage the nameserver via Terraform's `initialization.dns.servers` on
each LXC. Set to router initially; switch to DNSdist IP after Phase 3 via a second
`make plan+apply`. PKI LXCs are created after this switch and get DNSdist from birth._

---

### 1.2 Script-Level Dependency Matrix

| Script / Target | Hard prerequisites | Produces | Fails if missing |
|---|---|---|---|
| `make configure` | `config/<env>.yml` | tfvars, inventory, .envrc, .env.mk, allowed-cidrs | Validation error |
| `make build` | allowed-cidrs current | Squid image with ACL | Stale ACL, hosts unreachable |
| `make ansible-minio` | MinIO host exists, internet reachable from host | MinIO running (HTTP or HTTPS) | SSH timeout |
| `make bootstrap-minio` | MinIO running at `$MINIO_ENDPOINT` (HTTP), `$MINIO_ROOT_*` set | Bucket + scoped IAM key | Connection refused |
| `make init` | MinIO running + bucket + `$MINIO_ACCESS/SECRET_KEY` | `.terraform/` initialized | DNS/connection failure |
| `make plan` | `make init` done | `<env>.tfplan` | "Backend not initialized" |
| `make apply` | Plan file exists, Proxmox bridges + templates pre-created | LXCs/VMs on Proxmox | Bridge not found |
| `make ansible-pki` | PKI LXCs from TF, root-ca VM powered ON, `$STEP_CA_*` vars, group_vars filled | Issuing CA running :443 | SSH timeout or missing vars |
| `make ansible-env` | TF apply done, `.pki/root_ca.crt` on controller | Root CA trusted on all hosts | Warns and skips CA if cert missing |
| `make ansible-dns` | DNS LXCs from TF, `$PDNS_*` vars | Auth+Recursor only — **no records, no dist** | Missing vars |
| `ansible-playbook dns-records.yml` | `make ansible-dns` complete | A records in zone | 404 zone not found |
| `ansible-playbook dns-dist-setup.yml` | `make ansible-dns` complete (Recursor running) | DNSdist forwarding | Health check fail |
| `make ansible-nexus` | Nexus LXC from TF, `$NEXUS_ADMIN_PASSWORD` | Nexus running; **hard-fails if CA set and unreachable** | Assert failure |
| `make ansible-nexus` (TLS pass) | PKI running + managed host DNS resolving internal zone | Nexus + nginx + TLS | Cert issuance failure |

---

### 1.3 Additional Hidden Dependencies Found

**Dev container cannot resolve internal FQDNs — ever**
The dev container's path: process → Squid → Docker DNS → host DNS. Internal domains
(`*.lab.example.com`) never propagate through this path regardless of when PowerDNS
is deployed. `MINIO_ENDPOINT` must be IP-based from the dev container permanently.

**`make ansible-dns` is incomplete**
The Makefile target only runs `dns-setup.yml` (Auth + Recursor). It does not run
`dns-records.yml` or `dns-dist-setup.yml`. An operator following `make ansible-dns`
has PowerDNS running with an empty zone and no client-facing resolver.

**Nexus has no graceful TLS fallback**
MinIO's `tls.yml` checks CA health and skips TLS if unreachable — clean.
Nexus `main.yml:33` asserts `nexus_ca_url` upfront and `tls.yml` hard-fails if the
CA is unreachable. No partial deployment possible.

**MinIO TLS upgrade is a multi-step config change with no documentation**
Switching MinIO HTTP → HTTPS requires: config edit → `make configure` → re-source
`.envrc` → `make ansible-minio` → `make init` (re-init TF backend to new endpoint).
Nowhere documented. Missing `make init` after TLS upgrade leaves TF state on stale endpoint.

**No LXC `dns_servers` in Terraform modules today**
`proxmox-lxc` and `proxmox-vm` have no `dns_servers` variable. All LXCs inherit DNS
from Proxmox host defaults. No automated path to switch managed hosts to internal DNS.

**Packages bypass Nexus during initial deployment**
All 5 TF modules are unconditional. All LXCs are provisioned simultaneously.
DNS and PKI LXCs exist before Nexus is configured. Ansible roles (step_ca_common,
pdns_auth_recursor, etc.) install packages directly from the internet. Nexus cannot
be used as an apt proxy for other services until Nexus itself is deployed — but by
then the other LXCs already exist and have been through initial setup. Firewall cannot
be tightened until Nexus is up, which breaks the air-gap model.

---

## 2. Deployment Order Decision

**Decided order: MinIO → Nexus → DNS → PKI**

Rationale:
- MinIO must exist before any Terraform state can be stored
- Nexus must be up before the firewall is tightened (direct internet blocked) so subsequent
  service installs (DNS, PKI) pull packages through Nexus
- DNS must be up before PKI so that the PKI LXCs are created with DNSdist as their
  nameserver from birth (enabling FQDN-based `ca_url` resolution)
- PKI is last because TLS is the final hardening layer — all services run HTTP-only
  until PKI is ready, then TLS is applied in a single upgrade pass

---

## 3. Decisions Made

### 3.1 Incremental Terraform via `count`-based module gating

All 5 Terraform modules get gated behind `count = var.enable_<service> ? 1 : 0`.
Enable flags are explicit fields in `config/<env>.yml`. The generator emits them into
tfvars. No `-target` required — operator adds the flag, runs `make configure` +
`make plan+apply`.

```yaml
# config/sandbox.yml — operator adds each flag when ready to deploy that service
services:
  nexus:
    enabled: true    # add this to trigger make plan+apply for Nexus LXC
  pki:
    enabled: true
  dns:
    enabled: true
```

Terraform module gating:
```hcl
module "nexus" {
  count = var.enable_nexus ? 1 : 0
  ...
}
```

MinIO is excluded — it has no Terraform module and is pre-existing.

### 3.2 Terraform-managed DNS resolver switching

Add `dns_servers` variable to `proxmox-lxc` and `proxmox-vm` modules, wiring
`initialization.dns.servers`. The generator emits it into tfvars from a new
`infrastructure.dns_server` config field.

Workflow:
- **Initial TF apply (Phases 2–3):** `dns_server: <router_ip>` — LXCs get working
  external DNS for apt installs
- **After Phase 3 (DNS deployed):** update `dns_server: <dnsdist_ip>`, run
  `make configure` → `make plan+apply` — Proxmox pushes new nameserver into all
  running LXC `/etc/resolv.conf` live
- **Phase 4 (PKI):** PKI LXCs are created after the switch — born with DNSdist
  nameserver, `ca.lab.example.com` resolves from day 1

### 3.3 Nexus graceful TLS fallback + HTTP-only operating mode

Two changes to the Nexus role:

1. **`main.yml`:** Remove unconditional `nexus_ca_url` assert. Make TLS optional
   behind a `nexus_tls_enabled` flag (same pattern as MinIO's `minio_tls_enabled`).

2. **`tls.yml`:** Add CA health check at the top (same pattern as `minio/tasks/tls.yml`):
   ```yaml
   - name: Check issuing CA reachability
     ansible.builtin.uri:
       url: "{{ nexus_ca_url }}/health"
       validate_certs: false
       timeout: 5
     register: nexus_ca_health_check
     failed_when: false
   ```
   Skip TLS block if CA unreachable. Nexus runs on `:8081` HTTP-only without nginx.
   nginx is only wired up in the TLS upgrade pass (Phase 5).

### 3.4 MINIO_ENDPOINT always IP-based from dev container

Generator change: when `minio.tls: true`, emit:
```
MINIO_ENDPOINT="https://<minio_ip>:9000"
```
Never FQDN. The dev container cannot resolve internal FQDNs through Squid.

MinIO TLS cert issuance adds the MinIO IP as a SAN so TLS validates against the IP:
```
step ca certificate {{ minio_domain }}
  ...
  --san {{ minio_ipv4 }}   ← added
```

### 3.5 `make init` always uses `insecure=true` for S3 backend

After Phase 5 (MinIO TLS upgrade), the dev container's TLS stack cannot validate the
internal root CA cert. Fix: add `insecure=true` to the Terraform S3 backend init.
This flag is ignored when the endpoint is HTTP (Phases 1–4), so it is safe to add
permanently.

```makefile
make init:
    terraform init -reconfigure \
        -backend-config="bucket=$(TF_BUCKET)" \
        -backend-config="access_key=$$MINIO_ACCESS_KEY" \
        -backend-config="secret_key=$$MINIO_SECRET_KEY" \
        -backend-config="endpoints={s3=\"$$MINIO_ENDPOINT\"}" \
        -backend-config="insecure=true"
```

Note: `bootstrap-minio.sh` runs in Phase 1 (plain HTTP) — no TLS concern there.

### 3.6 `ca_url` stays FQDN-based for TF-managed hosts

Because PKI LXCs are created after the Phase 3 nameserver switch (decision 3.2),
they resolve `ca.lab.example.com` via DNSdist from birth. FQDN-based `ca_url` works
for all TF-managed services (Nexus, PKI health check).

MinIO is the exception — its host is pre-existing and not TF-managed. The generator
derives `minio_ca_url` from `pki.issuing_ca.ip` directly:
```
minio_ca_url: "https://<issuing_ca_ip>"
```
This is set in the `minio` group vars in `hosts.yml`. No DNS needed for MinIO cert
issuance or cert renewal timer.

### 3.7 Nexus as apt proxy (`nexus_apt_proxy` variable)

Firewall is tightened after Phase 2 (Nexus deployed). Phases 3+ (DNS, PKI) must
install packages through Nexus, not direct internet. Add `nexus_apt_proxy` variable to
roles that install packages:

- `common`
- `step_ca_common` / `step_client`
- `pdns_auth_recursor`
- `pdns_dnsdist`

When `nexus_apt_proxy` is set, each role configures an apt source pointing to the
Nexus proxy URL before installing packages. Generator derives the URL from
`services.nexus.ip` and emits it into group_vars `all`.

### 3.8 Makefile DNS targets

`make ansible-dns` currently runs only `dns-setup.yml`. Add two targets:

```makefile
ansible-dns-records: ## Populate DNS A records via PowerDNS API
    cd ansible && ansible-playbook -i inventory/ playbooks/dns-records.yml

ansible-dns-dist: ## Deploy DNSdist client-facing resolver
    cd ansible && ansible-playbook -i inventory/ playbooks/dns-dist-setup.yml
```

---

## 4. Complete Remediation Change List

| # | File | Change |
|---|------|--------|
| 1 | `config/sandbox.yml.example` | Add `services.nexus.enabled`, `services.dns.enabled`, `services.pki.enabled`; add `infrastructure.dns_server` field |
| 2 | `config/production.yml.example` | Same |
| 3 | `scripts/generate-configs.py` | Emit `enable_nexus/dns/pki` + `dns_server` into tfvars; emit `MINIO_ENDPOINT` as IP always; derive `minio_ca_url` from `pki.issuing_ca.ip`; emit `nexus_apt_proxy` into group_vars/all |
| 4 | `terraform/variables.tf` | Add `enable_nexus`, `enable_dns`, `enable_pki` (bool, default false); add `dns_servers` (list(string), default []) |
| 5 | `terraform/main.tf` | Add `count = var.enable_nexus ? 1 : 0` to `nexus`; `count = var.enable_dns ? 1 : 0` to `dns_auth` and `dns_dist`; `count = var.enable_pki ? 1 : 0` to `issuing_ca` and `root_ca` |
| 6 | `terraform/modules/proxmox-lxc/variables.tf` | Add `dns_servers` variable (`list(string)`, default `[]`) |
| 7 | `terraform/modules/proxmox-lxc/main.tf` | Add `dynamic "dns"` block inside `initialization` wiring `dns_servers` |
| 8 | `terraform/modules/proxmox-vm/variables.tf` | Same |
| 9 | `terraform/modules/proxmox-vm/main.tf` | Same (cloud-init DNS for root-ca VM) |
| 10 | `Makefile` | Add `insecure=true` to `make init`; add `ansible-dns-records` and `ansible-dns-dist` targets |
| 11 | `ansible/roles/nexus/tasks/main.yml` | Remove unconditional `nexus_ca_url` assert; gate TLS tasks on `nexus_tls_enabled` flag |
| 12 | `ansible/roles/nexus/tasks/tls.yml` | Add CA health check + graceful skip block (MinIO pattern) |
| 13 | `ansible/roles/nexus/defaults/main.yml` | Add `nexus_tls_enabled: false` default |
| 14 | `ansible/roles/minio/tasks/tls.yml` | Add `--san {{ minio_ipv4 }}` to `step ca certificate` command |
| 15 | `ansible/roles/minio/defaults/main.yml` | Add `minio_ipv4: ""` default |
| 16 | `ansible/roles/common/tasks/main.yml` | Add `nexus_apt_proxy` conditional apt source configuration |
| 17 | `ansible/roles/step_ca_common/tasks/main.yml` | Same |
| 18 | `ansible/roles/step_client/tasks/main.yml` | Same |
| 19 | `ansible/roles/pdns_auth_recursor/tasks/apt.yml` | Same |
| 20 | `ansible/roles/pdns_dnsdist/tasks/apt.yml` | Same |
| 21 | `ansible/inventory/group_vars/all/` | Add `nexus_apt_proxy: ""` default (set by generator when Nexus enabled) |

---

## 5. Final Deployment Runbook (Target State)

```
PHASE 0 — Operator pre-work (once per cluster)
  • Create Proxmox bridges for MGMT VLAN
  • Run scripts/setup-vm-template.sh on Proxmox host
  • pveam download <lxc-template>
  • Create MinIO host (manual LXC or bare metal — no TF module)

PHASE 1 — MinIO + Terraform init
  config: minio.tls: false, no enable_* flags set
  make configure
  make ansible-env --limit minio      # common baseline
  make ansible-minio                  # HTTP, IP endpoint
  make bootstrap-minio                # creates bucket + scoped IAM key
  # fill in MINIO_ACCESS_KEY/SECRET_KEY in .envrc
  direnv allow
  make init
  make plan && make apply             # no LXCs created yet (all enable_* false)

PHASE 2 — Nexus (HTTP)
  config: services.nexus.enabled: true
  make configure
  make plan && make apply             # creates Nexus LXC with router DNS
  make ansible-env --limit nexus      # common baseline
  make ansible-nexus                  # HTTP on :8081, no TLS
  # TIGHTEN FIREWALL: block direct internet from MGMT VLAN

PHASE 3 — DNS
  config: services.dns.enabled: true
  make configure
  make plan && make apply             # creates dns-auth + dns-dist LXCs with router DNS
  make ansible-env --limit dns_auth,dns_dist
  make ansible-dns                    # Auth + Recursor
  make ansible-dns-records            # populate A records
  make ansible-dns-dist               # DNSdist client resolver
  # switch managed host DNS to DNSdist:
  config: infrastructure.dns_server: <dnsdist_ip>
  make configure
  make plan && make apply             # nameserver pushed to all existing LXCs live

PHASE 4 — PKI
  config: services.pki.enabled: true
  make configure
  make plan && make apply             # issuing-ca LXC + root-ca VM
                                      # BORN with dnsdist_ip nameserver
  # Operator: power on root-ca VM in Proxmox UI
  make ansible-pki                    # root CA + issuing CA
  make ansible-env                    # re-run: distribute root CA cert to all hosts
  # Operator: power off root-ca VM

PHASE 5 — TLS upgrade
  config: services.minio.tls: true, services.minio.fqdn: minio.lab.example.com
  make configure                      # MINIO_ENDPOINT stays IP-based
  direnv allow
  make ansible-minio                  # TLS cert issued (IP SAN included), MinIO restarts HTTPS
  make init                           # re-init TF backend to HTTPS endpoint (insecure=true)
  make ansible-nexus                  # CA now reachable: cert issued, nginx wired up
  # Verify: make verify-isolation
```

---

## 6. What Is NOT In Scope (Future Work)

- **Switching existing services to Nexus repos** — Phases 1–2 install packages directly
  from the internet. Only Phase 3+ roles use `nexus_apt_proxy`. Re-running Phase 1–2
  roles after Nexus is up is a separate workstream.
- **Root CA cert in dev container trust store** — covered by `insecure=true` on the
  Terraform S3 backend. A full trust chain import into the dev container image is
  possible via Dockerfile but not required for this workflow.
- **DoT / DoH on DNSdist** — currently plain Do53 only. TLS-encrypted DNS is a
  future DNSdist configuration layer.
- **Nexus as Docker registry** — repos are bootstrapped but no roles configure Docker
  daemon to use the internal registry.
- **Cert renewal verification** — systemd timers are deployed for MinIO and Nexus
  cert renewal but no Ansible verification playbook exists for renewal smoke tests.
