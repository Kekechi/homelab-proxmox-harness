# Internal PKI Setup — step-ca Two-Tier CA

This document covers the full deployment sequence for the internal PKI: a two-tier step-ca
Certificate Authority with an offline Root CA (VM) and an always-on Issuing CA (LXC).

Two environments are supported:

| Environment | Network | Deployed by |
|---|---|---|
| Sandbox | Sandbox VLAN | Claude (`make apply`) |
| Production | Management VLAN | Operator manually |

---

## Architecture

```
Root CA (VM, normally off)
  └── signs the Issuing CA's intermediate certificate (boots only to sign/rotate)
  └── key: file-based today (HSM/PKCS#11 not currently wired in the roles)

Issuing CA (LXC, always on)
  └── ACME provisioner (named "acme") — automatic cert issuance + renewal for services
  └── binds :443 directly via setcap (no reverse proxy)
```

> The Issuing CA is created with a single ACME provisioner (`step ca init --acme`).
> There is no separate manual-issuance provisioner. The provisioner naming and the
> authority's `*.<domain>` policy scope are under review (a separate design item) —
> this guide documents what currently exists.

DNS records (add to your internal DNS resolver after deployment):

| Hostname | Network |
|---|---|
| `root-ca.<sandbox-domain>` | Sandbox VLAN |
| `ca.<sandbox-domain>` | Sandbox VLAN |
| `root-ca.<prod-domain>` | Management VLAN |
| `ca.<prod-domain>` | Management VLAN |

The `domain_name` value in `config/<env>.yml` controls what appears in the Terraform
DNS output hints after apply.

---

## Prerequisites

Before starting, ensure the following are in place:

- [ ] Proxmox node is accessible and the sandbox pool exists
- [ ] MinIO is running and `tfstate-sandbox` bucket exists (see `docs/guides/minio-setup.md`)
- [ ] Sandbox VLAN is trunked on the bridge and routed on your firewall
- [ ] Sandbox hosts can reach each other within the VLAN (east-west traffic allowed)
- [ ] Dev container is running with `direnv allow` applied

---

## Step 1 — Create the Debian 13 Cloud-Init VM Template

**Run once on the Proxmox host (as root).** This creates the VM template that Terraform
clones when provisioning the Root CA VM.

```bash
# Copy the script to the Proxmox host and run it
scp scripts/setup-vm-template.sh root@<proxmox-host>:/tmp/
ssh root@<proxmox-host> bash /tmp/setup-vm-template.sh
```

The script will:
1. Download the Debian 13 genericcloud image
2. Create VM with VMID 9000 (configurable via `TEMPLATE_VMID` env var)
3. Import and attach the disk (`local-lvm` storage by default — override with `STORAGE=`)
4. Add cloud-init drive, configure boot order, serial console
5. Resize disk to 8G and convert to template

**Storage override example:**
```bash
STORAGE=local-zfs TEMPLATE_VMID=9001 bash /tmp/setup-vm-template.sh
```

**Reproducibility note:** The script uses the `latest` Debian cloud image by default.
To pin to a specific snapshot, override the URL:
```bash
IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/<snapshot>/debian-13-genericcloud-amd64.qcow2" \
  bash /tmp/setup-vm-template.sh
```
Snapshot dates are listed at `https://cloud.debian.org/images/cloud/trixie/`.
For checksum verification, set `IMAGE_CHECKSUM="sha512:<hash>"` (hash from the
`SHA512SUMS` file on the same page).

After the script completes, the template will appear in the Proxmox UI as `debian-13-cloudinit`.
Verify it is marked as a template (gold icon).

---

## Step 2 — Configure the Environment

```bash
# In the dev container
cp config/sandbox.yml.example config/sandbox.yml
```

Edit `config/sandbox.yml` and fill in the `services.pki` section with your network values.
The SSH key for both PKI hosts is inherited from the top-level `ssh.public_key` — no
separate key needed.

```yaml
domain_name: "sandbox.example.com"     # used in Terraform DNS output hints

services:
  pki:
    enabled: true                       # gates the Terraform module (enable_pki); must be true to deploy
    root_ca:
      node: pve1                         # Proxmox node the cloud-init template lives on
      ip: "192.168.X.X/24"             # CIDR notation required for cloud-init static IP
      vm_id: 201                         # must not conflict with existing VMs
      ansible_user: debian
      hostname: root-ca                  # Ansible inventory alias (not a DNS label)
      ca_name: "Homelab Root CA"         # CN written into the root certificate
      cloud_init_template_id: 9000       # VMID from Step 1
    issuing_ca:
      node: pve1
      ip: "192.168.X.X/24"
      ct_id: 202
      ansible_user: root
      hostname: issuing-ca
      ca_name: "Homelab Issuing CA"      # CN written into the intermediate certificate
```

> Production additionally sets `network: mgmt` on both hosts (see
> `config/production.yml.example`). The gateway is resolved by the generator from the
> service's network — there is no per-host `gateway:` key.

Regenerate config files:

```bash
make configure
```

Fill in the new step-ca secrets in `.envrc`:

```bash
# .envrc — fill in these three new entries (in addition to existing secrets)
export STEP_CA_ROOT_PASSWORD="..."        # encrypts/decrypts the Root CA private key
export STEP_CA_ISSUING_PASSWORD="..."     # encrypts the intermediate (Issuing CA) private key
export STEP_CA_PROVISIONER_PASSWORD="..." # encrypts the ACME provisioner's JWK key

direnv allow
```

---

## Step 3 — Download the LXC Template

The Issuing CA LXC needs a Debian 13 LXC template on Proxmox storage.
Download it via the Proxmox UI:

> Datacenter → \<node\> → local → CT Templates → Templates → `debian-13-standard`

Or via shell on the Proxmox host:

```bash
pveam update
pveam download local debian-13-standard_13.0-1_amd64.tar.zst
```

Ensure the Debian 13 standard LXC template is present on Proxmox storage before the
Terraform apply in Step 4 — the issuing CA LXC clones from it.

---

## Step 4 — Terraform: Provision the VMs

```bash
make init      # initialises with tfstate-sandbox bucket on MinIO
make plan      # review the plan — expect: 2 resources to create (root-ca VM, issuing-ca LXC)
make apply     # applies sandbox.tfplan
```

After apply, Terraform outputs the DNS records to add:

```
pki_dns_records = {
  "ca"      = { ip = "192.168.X.X/24", record = "ca.<sandbox-domain>" }
  "root-ca" = { ip = "192.168.X.X/24", record = "root-ca.<sandbox-domain>" }
}
```

**Add these A records to your internal DNS resolver** (strip the CIDR prefix — use the IP only).

The `pki_root_ca` and `pki_issuing_ca` Ansible inventory groups are auto-derived from the
`pki:` IPs in `config/sandbox.yml` — no manual inventory edit needed. Verify Ansible can
reach both hosts:

```bash
# ansible.cfg is in ansible/ — run from that directory, or set ANSIBLE_CONFIG
cd ansible
ansible -i inventory/hosts.yml pki_root_ca:pki_issuing_ca -m ping
```

> **Note:** All Ansible commands in this doc must be run from `/workspace/ansible/` (where
> `ansible.cfg` lives), or with `ANSIBLE_CONFIG=/workspace/ansible/ansible.cfg` set.
> Without this, the SSH ProxyCommand is not applied and hosts will be unreachable.

---

## Step 5 — Ansible: Bootstrap the PKI

The PKI setup playbook is a single run. The Root CA VM must be **powered on** while it
runs: the root play generates the root certificate and key, and the issuing play signs
the intermediate locally using the root key (staged on the controller). There is no
CSR exchange and no second pass.

> **Root CA VM:** Terraform creates it with `started = false`
> (`terraform/main.tf` — root CA module). Start it manually in the Proxmox UI (or
> `qm start <vmid>`) **before** running the playbook. After the playbook completes,
> power it off again — it should remain off during normal operation.

```bash
# Preferred — runs ansible-playbook -i inventory/ playbooks/pki-setup.yml
make ansible-pki

# Equivalent raw invocation (ansible.cfg supplies the inventory + proxy):
cd ansible && ansible-playbook playbooks/pki-setup.yml
```

The playbook runs four plays over both hosts, in order:
1. **`common`** — selects apt sources, bootstraps internal root-CA trust, and writes the
   `/etc/hosts` mesh so `ca.<domain>` resolves before internal DNS exists.
2. **`step_ca_common`** — installs `step-cli` on both hosts and `step-ca` on the issuing
   CA only; creates the `step` user and directory layout.
3. **`step_ca_root`** (root CA host) — generates the root certificate and key, then
   fetches both to the controller staging dir `/workspace/.pki/`.
4. **`step_ca_issuing`** (issuing CA host) — runs `step ca init --acme` using the staged
   root key to sign the intermediate, applies the authority policy, sets
   `cap_net_bind_service` on the `step-ca` binary, and starts the service on `:443`. The
   staged root key is deleted from the controller and the issuing host after init.

The playbook is idempotent — re-running it detects existing certs and the initialized
issuing CA (stat checks) and skips regeneration.

> **Required env vars** (set in `.envrc`, then `direnv allow`): `STEP_CA_ROOT_PASSWORD`,
> `STEP_CA_ISSUING_PASSWORD`, `STEP_CA_PROVISIONER_PASSWORD`. The plays assert all three
> are non-empty before acting.

---

## Step 6 — Verify the Issuing CA

From any host on the sandbox VLAN:

```bash
# Health check — should return step-ca server info
curl https://ca.<your-domain>/health \
  --cacert /workspace/.pki/root_ca.crt

# List provisioners
step ca provisioner list \
  --ca-url https://ca.<your-domain> \
  --root /workspace/.pki/root_ca.crt
```

The root cert was already fetched to the controller staging dir during Step 5 — it lives
at `/workspace/.pki/root_ca.crt` (the `step_ca_controller_staging_dir`). The `common` role
distributes it to managed hosts from there.

It is also downloadable from step-ca's built-in API if you need a fresh copy:

```bash
# Accept the TLS warning on first use — this is expected:
curl -k https://ca.<your-domain>/roots.pem -o root_ca.crt
```

---

## Step 7 — Distribute the Root Certificate

The root CA certificate is automatically distributed to all Ansible-managed hosts
via the `common` role. Running any playbook that includes `common` (e.g. `site.yml`)
is sufficient — no separate step needed.

```bash
# Run from /workspace/ansible (or set ANSIBLE_CONFIG=/workspace/ansible/ansible.cfg)
cd ansible
ansible-playbook playbooks/site.yml
```

For personal devices and browsers, see `docs/guides/trust-root-ca.md` for per-platform
installation instructions.

---

## Root CA Operations

The Root CA VM should remain **powered off** under normal operation.
Start it only when you need to renew the intermediate certificate (typically once per year).

**To renew the intermediate certificate:**

```bash
# 1. Start the Root CA VM (Proxmox UI or CLI)
qm start <root-ca-vmid>

# 2. Re-run the PKI setup playbook
ansible-playbook ansible/playbooks/pki-setup.yml

# 3. Power off the Root CA VM
qm stop <root-ca-vmid>
```

**Proxmox backup** covers the Root CA key (encrypted with `STEP_CA_ROOT_PASSWORD`).
Store this password securely — losing it requires a full PKI rebuild.

---

## Production Deployment

Production uses the same IaC with different config values. The operator runs all
Terraform and Ansible steps manually from their workstation — Claude does not apply
to production.

```bash
# Generate production config
make configure ENV=production

# Plan only — operator reviews and applies
make plan ENV=production
# → produces terraform/production.tfplan for operator review

# Operator applies:
terraform apply production.tfplan

# Ansible (same playbooks, different inventory)
ansible-playbook ansible/playbooks/pki-setup.yml
ansible-playbook ansible/playbooks/site.yml  # common role handles cert distribution
```
