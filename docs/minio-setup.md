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

## Step 0 — Generate SSH keypair (dev container, one-time)

The dev container cannot `pct exec` into LXCs (PVE 9 removed this API endpoint). Instead,
generate an SSH keypair in the dev container and inject the public key via the Proxmox GUI shell.

```bash
# From the dev container workspace root
mkdir -p .ssh
ssh-keygen -t ed25519 -C "claude-sandbox" -f .ssh/id_ed25519 -N ""
cat .ssh/id_ed25519.pub  # Copy this for Step 1
```

The key lives at `.ssh/id_ed25519` (gitignored). It is accessible inside the container at
`/workspace/.ssh/id_ed25519` via the existing workspace bind mount — no extra volume needed.

Update `config/sandbox.yml` with the public key and regenerate:
```bash
# Set ssh.public_key in config/sandbox.yml, then:
make configure
```

**Host access (optional):** Symlink into host `~/.ssh` for manual SSH:
```bash
ln -s /path/to/project/.ssh/id_ed25519 ~/.ssh/id_ed25519_sandbox
# Then: ssh -i ~/.ssh/id_ed25519_sandbox root@10.10.40.100
```

---

## Step 1 — Bootstrap SSH on the LXC (operator, Proxmox GUI shell)

The LXC (VM ID 100, IP 10.10.40.100) starts blank — no sshd, no keys. Run these commands
in the **Proxmox node shell** (not the LXC console) to prepare it:

```bash
# Install openssh-server
pct exec 100 -- apt-get update
pct exec 100 -- apt-get install -y openssh-server

# Inject SSH public key for root
pct exec 100 -- mkdir -p /root/.ssh
pct exec 100 -- chmod 700 /root/.ssh
pct exec 100 -- bash -c 'echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIORd3TLyUldIEIJfsOe75l+r6/QIUa1GYbB5f56AhwIo claude-sandbox" > /root/.ssh/authorized_keys'
pct exec 100 -- chmod 600 /root/.ssh/authorized_keys

# Start sshd
pct exec 100 -- systemctl enable ssh
pct exec 100 -- systemctl start ssh
```

Verify from the dev container:
```bash
ssh -i /workspace/.ssh/id_ed25519 \
    -o ProxyCommand="ncat --proxy squid-proxy:3128 --proxy-type http %h %p" \
    -o StrictHostKeyChecking=accept-new \
    root@10.10.40.100 hostname
```

---

## Step 2 — Install MinIO via Ansible

Set up vault credentials before running the playbook:

```bash
# Fill in MinIO root credentials
vim ansible/inventory/group_vars/all/vault.yml
# Set minio_root_user and minio_root_password, then encrypt:
ansible-vault encrypt ansible/inventory/group_vars/all/vault.yml

# Fetch MinIO binary checksum from the LXC (which has direct internet access)
ssh root@10.10.40.100 \
  "curl -fsSL https://dl.min.io/server/minio/release/linux-amd64/minio.sha256sum" \
  | awk '{print $1}'
# Set the result in ansible/roles/minio/defaults/main.yml -> minio_checksum
```

Run the playbook:
```bash
make ansible-minio
# or manually:
ansible-playbook -i ansible/inventory/ ansible/playbooks/minio-setup.yml --limit minio
```

Verify:
```bash
curl -s http://10.10.40.100:9000/minio/health/live
# Expected: HTTP 200
```

---

## Step 3 — Bootstrap Buckets and IAM

The `mc` (MinIO Client) binary must be installed in the dev container. It is included in the
Dockerfile — rebuild the container if not already present:
```bash
make build  # then reopen dev container
```

Run the bootstrap script with the MinIO admin credentials from your vault:
```bash
export MINIO_ENDPOINT="http://10.10.40.100:9000"
export MINIO_ADMIN_ACCESS_KEY="<minio_root_user from vault>"
export MINIO_ADMIN_SECRET_KEY="<minio_root_password from vault>"
bash scripts/bootstrap-minio.sh
```

The script outputs sandbox-scoped credentials. Add them to `.envrc`:
```bash
export MINIO_ACCESS_KEY="terraform-sandbox-<generated>"
export MINIO_SECRET_KEY="<generated>"
```

Then initialize Terraform:
```bash
make init && make plan
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
