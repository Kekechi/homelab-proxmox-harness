# Sandbox Deployment Guide

Step-by-step walkthrough for deploying a fresh sandbox from scratch.
Services are brought up in dependency order across five phases.

**Prerequisites:** Proxmox cluster (or single node) ready with bridges, storage, and
templates in place — see `docs/cluster-setup.md`. IAM (pool, service account token)
configured — see `docs/proxmox-iam.md`.

---

## 1. Config setup

```bash
cp config/sandbox.yml.example config/sandbox.yml
```

Fill in `config/sandbox.yml`:

| Field | What to set |
|---|---|
| `domain_name` | Internal domain (e.g. `lab.example.com`) |
| `ssh.public_key` | SSH public key from `docs/minio-setup.md` Step 0 |
| `infrastructure.proxmox.ip` | Proxmox API IP |
| `infrastructure.nodes.*` | Node name → IP for each cluster node |
| `infrastructure.networks.*` | Bridge name, subnet CIDR, gateway |
| `infrastructure.storage.*` | Datastore IDs and LXC template file ID |
| `terraform.pool_id` | Proxmox resource pool name |
| `services.minio.*` | IP, port, hostname — set `tls: false` for now |
| `services.pki.*` | IPs, CT/VM IDs, hostnames — `enabled: false` |
| `services.dns.*` | IPs, CT IDs, hostnames — `enabled: false` |
| `services.nexus.*` | IP, CT ID, hostname, FQDN — `enabled: false` |
| `infrastructure.dns_server` | Router IP — switch to DNSdist IP after Phase 3 |

**All service `enabled:` fields must be `false` for Phase 1.**

Generate downstream config:

```bash
make configure
```

The generator writes `terraform/sandbox.tfvars`, `ansible/inventory/hosts.yml`,
`.devcontainer/squid/allowed-cidrs.conf`, `.envrc` (with `CHANGE_ME` placeholders),
and `.env.mk`.

> If `allowed-cidrs.conf` changed, run `make build` and reopen the dev container
> so Squid picks up the new allowlist.

Fill in secrets in `.envrc` — these are marked `CHANGE_ME` by the generator:

```
PROXMOX_VE_API_TOKEN    # terraform@pve!claude-sandbox=<uuid>
MINIO_ROOT_USER         # admin username you choose
MINIO_ROOT_PASSWORD     # admin password you choose
```

> `MINIO_ACCESS_KEY` and `MINIO_SECRET_KEY` are filled in after Phase 1 bootstrap.
> Phase-specific secrets (`NEXUS_ADMIN_PASSWORD`, `PDNS_*`, `STEP_CA_*`) can wait
> until the relevant phase.

---

## Phase 1 — MinIO + Terraform init

MinIO is not a Terraform resource — it is created manually and bootstrapped via Ansible.
It must be running before `make init` can initialize the Terraform state backend.

Follow **all steps** in `docs/minio-setup.md`:

| Step | Action |
|---|---|
| Step 0 | Generate SSH keypair (already done if `ssh.public_key` is set) |
| Step 1 | Create the MinIO LXC in Proxmox GUI, bootstrap SSH via `pct exec` |
| Step 2 | Fetch MinIO checksum, run `make ansible-minio` |
| Step 3 | Run `make bootstrap-minio` — copy `MINIO_ACCESS_KEY` and `MINIO_SECRET_KEY` output into `.envrc` |

Then initialize Terraform and validate the empty plan:

```bash
direnv allow          # reload .envrc with the new keys
make init
make plan             # expect: 0 resources to add/change/destroy (all enables are false)
```

> A clean empty plan confirms the backend, provider auth, and tfvars are all wired
> correctly before any infra is created.

---

## Phase 2 — Nexus (HTTP)

Fill in `.envrc`:
```
NEXUS_ADMIN_PASSWORD    # admin password you choose
```

Enable Nexus in `config/sandbox.yml`:
```yaml
services:
  nexus:
    enabled: true
```

```bash
make configure
make plan
make apply
```

Nexus LXC is now created on Proxmox with the router as its DNS resolver.

```bash
make ansible-env          # distribute root CA cert (no-op until Phase 4 — safe to run now)
make ansible-nexus        # install + configure Nexus CE; TLS disabled at this phase
```

Verify: Nexus UI is reachable on port 8081 from the MGMT network.

After verifying, tighten the firewall to block direct internet from the MGMT VLAN
(Nexus becomes the APT proxy for subsequent phases).

---

## Phase 3 — DNS

Fill in `.envrc`:
```
PDNS_AUTH_API_KEY       # any strong string
PDNS_RECURSOR_API_KEY   # any strong string
PDNS_DNSDIST_API_KEY    # any strong string
```

Enable DNS in `config/sandbox.yml`:
```yaml
services:
  dns:
    enabled: true
```

```bash
make configure
make plan
make apply
```

dns-auth and dns-dist LXCs are created, both using the router as their initial DNS.

```bash
make ansible-dns            # deploy PowerDNS Auth + Recursor
make ansible-dns-records    # populate A records in the zone
make ansible-dns-dist       # deploy DNSdist, wire forwarding to Recursor
```

Verify DNS is resolving before switching:
```bash
# From the dev container, through Squid:
sandbox-ssh root@<dns-dist-ip> "dig +short nexus.<domain>"
```

**Switch all managed hosts to DNSdist.** In `config/sandbox.yml`:
```yaml
infrastructure:
  dns_server: "<dns-dist-ip>"   # DNSdist IP
```

```bash
make configure
make plan       # will show dns_servers update on running LXCs (Nexus, dns-auth, dns-dist)
make apply      # Terraform pushes new resolv.conf to all TF-managed LXCs
```

MinIO is not Terraform-managed — update its resolver manually or via a targeted
Ansible task before Phase 5 (required for MinIO TLS cert issuance to resolve
`ca.<domain>`).

**One-time: point the dev container Squid at internal DNS.**
This allows the dev container to resolve internal FQDNs through the proxy —
required so `make init` can connect to MinIO by hostname in Phase 5.

```bash
echo "dns_nameservers <dns-dist-ip>" >> .devcontainer/squid/squid.conf.local
make build
# Reopen the dev container when prompted
```

> `squid.conf.local` is gitignored (`*.local`). This step only needs to be
> redone if you delete the file or rebuild from scratch.

---

## Phase 4 — PKI

Fill in `.envrc`:
```
STEP_CA_ROOT_PASSWORD         # protects Root CA private key
STEP_CA_ISSUING_PASSWORD      # protects Issuing CA private key
STEP_CA_LXC_ROOT_PASSWORD     # root account password for Issuing CA LXC
STEP_CA_PROVISIONER_PASSWORD  # JWK provisioner password (used by TLS setup)
```

Enable PKI in `config/sandbox.yml`:
```yaml
services:
  pki:
    enabled: true
```

```bash
make configure
make plan
make apply      # creates issuing-ca LXC and root-ca VM (root-ca starts powered OFF)
```

**Operator step:** Power on the root-ca VM in the Proxmox UI — it is kept offline
at all other times. Only start it for the initial signing step below.

```bash
make ansible-pki    # initialize Root CA, sign Issuing CA CSR, start Issuing CA service
make ansible-env    # distribute root CA cert to all managed hosts
```

**Operator step:** Power off the root-ca VM in the Proxmox UI.

Verify from any managed host:
```bash
sandbox-ssh root@<issuing-ca-ip> "step ca health --ca-url https://ca.<domain> --root /etc/step-ca/certs/root_ca.crt"
# expected: ok
```

---

## Phase 5 — TLS upgrade

Enable MinIO TLS in `config/sandbox.yml`:
```yaml
services:
  minio:
    tls: true
```

```bash
make configure
```

> `MINIO_ENDPOINT` in `.envrc` is FQDN-based when `tls: true`. The dev container
> Squid proxy resolves it via DNSdist (configured in Phase 3) — no IP SAN needed.

```bash
make ansible-minio    # issues TLS cert from Issuing CA, restarts MinIO on HTTPS
make init             # re-initialize Terraform backend (MinIO endpoint now HTTPS)
make ansible-nexus    # TLS pass: Issuing CA now reachable, issues Nexus cert, wires nginx
```

Final verification:
```bash
make verify-isolation
```

Expected: all internal endpoints reachable over HTTPS, direct internet blocked from
MGMT VLAN.
