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
  └── signs Intermediate CA certificate once per year
  └── key: file-based (PKCS#11/YubiKey path available via config change)

Issuing CA (LXC, always on)
  └── ACME provisioner  — automatic cert renewal for services
  └── JWK provisioner   — manual/one-off cert issuance
  └── nginx TCP proxy   — forwards :443 → step-ca:9000
  └── serves root.crt   — at /var/www/html/root.crt for manual trust installs
```

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
- [ ] MinIO is running and `tfstate-sandbox` bucket exists (see `docs/minio-setup.md`)
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
    root_ca:
      ip: "192.168.X.X/24"             # CIDR notation required for cloud-init static IP
      gateway: "192.168.X.1"
      vm_id: 201                        # must not conflict with existing VMs
      ansible_user: debian
      hostname: root-ca
      cloud_init_template_id: 9000      # VMID from Step 1
    issuing_ca:
      ip: "192.168.X.X/24"
      gateway: "192.168.X.1"
      ct_id: 202
      ansible_user: root
      hostname: issuing-ca
      lxc_template_file_id: "local:vztmpl/debian-13-standard_13.0-1_amd64.tar.zst"
```

Regenerate config files:

```bash
make configure
```

Fill in the new step-ca secrets in `.envrc`:

```bash
# .envrc — fill in these three new entries (in addition to existing secrets)
export STEP_CA_ROOT_PASSWORD="..."      # protects the Root CA private key
export STEP_CA_ISSUING_PASSWORD="..."   # protects the Issuing CA private key
export STEP_CA_LXC_ROOT_PASSWORD="..."  # root account password for the Issuing CA LXC

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

Verify the template file ID matches what is set in `config/sandbox.yml`:
```yaml
services:
  pki:
    issuing_ca:
      lxc_template_file_id: "local:vztmpl/debian-13-standard_13.0-1_amd64.tar.zst"
```

If your template storage is not `local`, update `lxc_template_file_id` accordingly.

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
In OPNsense Unbound: Services → Unbound DNS → Host Overrides → Add.

The `pki_root_ca` and `pki_issuing_ca` Ansible inventory groups are auto-derived from the
`pki:` IPs in `config/sandbox.yml` — no manual inventory edit needed. Verify Ansible can
reach both hosts:

```bash
ansible -i ansible/inventory/hosts.yml pki_root_ca:pki_issuing_ca -m ping
```

---

## Step 5 — Ansible: Bootstrap the PKI

The PKI setup playbook must be run in two passes because the Root CA must be online
to sign the Issuing CA's intermediate CSR.

**Pass 1 — Common setup and CSR generation:**

```bash
ansible-playbook ansible/playbooks/pki-setup.yml
```

This will:
1. Install step-cli and step-ca binaries on both hosts
2. Generate the Root CA certificate and key
3. Generate the Issuing CA intermediate key and CSR
4. Fetch the CSR to `/tmp/ansible-pki/intermediate_ca.csr` on the controller

> **Root CA VM:** The VM was created with `started = false`. Start it manually in the
> Proxmox UI (or via `qm start <vmid>`) before running the playbook. After the playbook
> completes the signing step, power it off again — it should remain off during normal operation.

**Pass 2 — Deploy signed certificate and start services:**

After the root CA has signed the intermediate CSR, re-run the playbook to deploy
the signed cert and start the Issuing CA service:

```bash
ansible-playbook ansible/playbooks/pki-setup.yml
```

The playbook is idempotent — it detects the signed cert and proceeds to configure
and start step-ca and nginx on the Issuing CA.

---

## Step 6 — Verify the Issuing CA

From any host on the sandbox VLAN:

```bash
# Health check — should return step-ca server info
curl https://ca.<your-domain>/health \
  --cacert /tmp/ansible-pki/root_ca.crt

# List provisioners
step ca provisioner list \
  --ca-url https://ca.<your-domain> \
  --root /tmp/ansible-pki/root_ca.crt
```

The root cert is also available for download at:

```
https://ca.<your-domain>/root.crt
```

---

## Step 7 — Distribute the Root Certificate

Push the root cert to all managed hosts so that curl, apt, and other tools trust the CA:

```bash
ansible-playbook ansible/playbooks/distribute-root-cert.yml --limit sandbox
ansible-playbook ansible/playbooks/distribute-root-cert.yml --limit minio
```

For personal devices and browsers, download and install manually from:
```
https://ca.<your-domain>/root.crt
```

Installation guides:
- **macOS:** Double-click → Keychain Access → set "Always Trust"
- **Linux:** Copy to `/usr/local/share/ca-certificates/` → run `sudo update-ca-certificates`
- **Firefox:** Preferences → Privacy & Security → Certificates → View Certificates → Import
- **Chrome/Edge:** Uses the OS trust store (Linux/macOS) — no separate browser step needed

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
ansible-playbook ansible/playbooks/distribute-root-cert.yml --limit production
```
