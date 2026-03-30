# MinIO Setup

MinIO runs as an LXC container on Proxmox and serves as the Terraform remote state backend.
It is accessible from any device on the internal network (and via VPN).

## Why MinIO

- Lightweight: runs in ~512 MB RAM as an LXC container
- S3-compatible: works with Terraform's standard `s3` backend
- Self-hosted: state stays on your internal network
- Versioning: state file recovery after failed applies
- **Future migration:** swap to GitLab HTTP backend with one `backend.tf` change

---

## Step 1 — Create the LXC on Proxmox

In the Proxmox UI or via CLI:

```bash
# Download Ubuntu 24.04 LXC template (if not already present)
pveam download local ubuntu-24.04-standard_24.04-2_amd64.tar.zst

# Create LXC (adjust VMID, storage, and IP to your environment)
pct create 150 local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
  --hostname minio \
  --cores 1 \
  --memory 1024 \
  --swap 512 \
  --rootfs local-lvm:8 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.X.X/24,gw=192.168.X.1 \
  --unprivileged 1 \
  --start 1
```

---

## Step 2 — Install MinIO via Ansible

```bash
# Add the MinIO LXC to config/sandbox.yml under the hosts.minio group:
#
# hosts:
#   minio:
#     minio-server:
#       ansible_host: 192.168.X.X
#       ansible_user: root
#
# Then regenerate the inventory:
make configure

# Set up ansible vault with MinIO root credentials before running the playbook.
# See ansible/inventory/group_vars/all/vault.yml.example for required variables.

ansible-playbook -i ansible/inventory/ ansible/playbooks/minio-setup.yml --limit minio
```

Or manually inside the LXC:

```bash
curl -fsSL https://dl.min.io/server/minio/release/linux-amd64/minio \
  -o /usr/local/bin/minio && chmod +x /usr/local/bin/minio

# Create data directory and user
useradd -r -s /sbin/nologin minio-user
mkdir -p /var/lib/minio/data
chown -R minio-user:minio-user /var/lib/minio

# Create environment file
cat > /etc/minio/minio.env <<EOF
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=CHANGE_ME_SECURE_PASSWORD
MINIO_VOLUMES=/var/lib/minio/data
MINIO_OPTS="--console-address :9001"
EOF

# Install and start systemd service (see Ansible role for service template)
systemctl enable --now minio
```

---

## Step 3 — Bootstrap Buckets and IAM

Run from host or dev container (MinIO must be reachable):

```bash
# Set admin credentials
export MINIO_ENDPOINT="http://192.168.X.X:9000"
export MINIO_ADMIN_ACCESS_KEY="minioadmin"
export MINIO_ADMIN_SECRET_KEY="CHANGE_ME_SECURE_PASSWORD"

# Run bootstrap script — creates buckets, versioning, sandbox IAM policy + user
bash scripts/bootstrap-minio.sh
```

The script outputs the sandbox-scoped access key and secret. Add them to `.envrc`:
```bash
export MINIO_ACCESS_KEY="terraform-sandbox-<generated>"
export MINIO_SECRET_KEY="<generated>"
```

---

## Bucket Layout

| Bucket | Access | Managed by |
|---|---|---|
| `tfstate-sandbox` | Claude's scoped key (read/write) | Terraform sandbox env |
| `tfstate-production` | Operator's admin key only | Operator from workstation |

---

## Future Migration to GitLab HTTP Backend

When ready to adopt GitLab:

1. Pull current state: `terraform state pull > backup.tfstate`
2. Replace the `backend "s3"` block in each environment's `backend.tf` with:
   ```hcl
   backend "http" {
     address        = "https://<gitlab>/api/v4/projects/<id>/terraform/state/<env>"
     lock_address   = "https://<gitlab>/api/v4/projects/<id>/terraform/state/<env>/lock"
     unlock_address = "https://<gitlab>/api/v4/projects/<id>/terraform/state/<env>/lock"
     username       = "terraform"
     password       = var.gitlab_token
     lock_method    = "POST"
     unlock_method  = "DELETE"
     retry_wait_min = 5
   }
   ```
3. Run `terraform init -migrate-state`
4. Verify: `terraform state list`

No module or variable changes required.
