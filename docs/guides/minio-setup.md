# MinIO Setup

MinIO runs as an LXC container on Proxmox and serves as the Terraform remote state backend.
It is reached directly from the controller (agent) host over SSH and HTTP(S).

Each environment has its own MinIO instance on its own VNet. **Run this entire setup process
once per environment**, pointing at that environment's MinIO host.

## Why MinIO

- Lightweight: runs in ~512 MB RAM as an LXC container
- S3-compatible: works with Terraform's standard `s3` backend
- Self-hosted: state stays on your internal network
- Versioning: state file recovery after failed applies
- **Future migration:** swap to GitLab HTTP backend with one `backend.tf` change

---

## Step 0 — Generate SSH keypair (controller host, one-time)

Generate an SSH keypair on the controller (agent) host; the public key is injected
into the MinIO LXC at create time (via cloud-init in Step 1). Use a comment that
names the environment so the key is identifiable — substitute the env name literally.

```bash
# On the controller host (replace <ENV> with sandbox/production)
ssh-keygen -t ed25519 -C "claude-<ENV>" -f ~/.ssh/id_ed25519 -N ""
cat ~/.ssh/id_ed25519.pub  # Copy this into config/<ENV>.yml (ssh.public_key)
```

The private key lives wherever `agent.ssh_private_key` in `config/<ENV>.yml` points
(default `~/.ssh/id_ed25519`) — `make configure` writes that path into the generated
`ansible/ansible.cfg`, so Ansible and manual SSH use the same key.

Update `config/<ENV>.yml` with the public key and regenerate:
```bash
# Set ssh.public_key in config/<ENV>.yml, then:
make configure ENV=<ENV>
```

---

## Step 1 — Create the MinIO LXC (controller host, API + cloud-init)

MinIO is outside the Terraform graph (it holds the TF state bucket — bootstrap
paradox), so it is created with a direct Proxmox API call and cloud-init, then
provisioned by Ansible. With `ssh.public_key` set in `config/<ENV>.yml` and
`make configure` run, create the LXC:

```bash
make loop-minio                       # sandbox (default)
make loop-minio ENV=production        # production
# or directly:
bash scripts/loop/recreate-minio.sh <ENV>
```

This creates an unprivileged LXC (nesting enabled, 8G rootfs) on the node and
network from `config/<ENV>.yml`, injects the public key via cloud-init, starts
it, and blocks until sshd is reachable. Verify from the controller host (replace
`<MINIO_HOST>` with the IP from `config/<ENV>.yml`):

```bash
sandbox-ssh -i ~/.ssh/id_ed25519 \
    -o StrictHostKeyChecking=accept-new \
    root@<MINIO_HOST> hostname
```

`sandbox-ssh` is an agent-host alias for plain `ssh` — it exists only to satisfy
Claude Code's Bash permission rules for `ssh`. When running these steps by hand
as the operator, plain `ssh` is equivalent.

<details>
<summary>Legacy fallback — manual SSH bootstrap via the Proxmox node shell</summary>

If the API create path is unavailable, prepare a blank LXC manually. Run these in
the **Proxmox node shell** (not the LXC console). Replace `<VM_ID>` with the LXC's
ID and `<PUBLIC_KEY>` with the key from Step 0.

```bash
pct exec <VM_ID> -- apt-get update
pct exec <VM_ID> -- apt-get install -y openssh-server
pct exec <VM_ID> -- mkdir -p /root/.ssh
pct exec <VM_ID> -- chmod 700 /root/.ssh
pct exec <VM_ID> -- bash -c 'echo "<PUBLIC_KEY>" > /root/.ssh/authorized_keys'
pct exec <VM_ID> -- chmod 600 /root/.ssh/authorized_keys
pct exec <VM_ID> -- systemctl enable ssh
pct exec <VM_ID> -- systemctl start ssh
```
</details>

---

## Step 2 — Install MinIO via Ansible

MinIO root credentials are read at playbook runtime from `.envrc` via `lookup('env', ...)`.
Ensure these are set before running:

```bash
# In .envrc — these two are CHANGE_ME placeholders you fill in manually:
export MINIO_ROOT_USER="<your-admin-username>"
export MINIO_ROOT_PASSWORD="<your-admin-password>"
```

`MINIO_ENDPOINT` is generated into `.envrc` automatically by `make configure`
(do not hand-set it). Its scheme follows `services.minio.tls` in `config/<ENV>.yml`.

**TLS (`services.minio.tls`):** when `true` (the example default), MinIO serves
HTTPS with a cert issued by the internal CA, and `MINIO_ENDPOINT` is `https://`
on the service FQDN — so `services.minio.fqdn` is required (the generator errors
without it). `make configure` also emits `AWS_CA_BUNDLE` into `.envrc` so
Terraform's S3 client trusts the internal root CA. Set `tls: false` for plain
HTTP. The Ansible role picks up the TLS settings from the generated inventory; do
not hardcode them in the role.

Fetch the MinIO binary checksum from the LXC (which has direct internet access):
```bash
sandbox-ssh root@<MINIO_HOST> \
  "curl -fsSL https://dl.min.io/server/minio/release/linux-amd64/minio.sha256sum" \
  | awk '{print $1}'
# Set the result in components/minio/roles/minio/defaults/main.yml -> minio_checksum
```

Run the playbook:
```bash
make ansible-minio
# or manually (from ansible/ so the generated cfg + inventory apply):
cd ansible && ansible-playbook -i inventory/ ../components/minio/playbook.yml --limit minio
```

Verify (canonical — auto-selects the scheme from `minio.tls` and checks both
liveness and readiness):
```bash
make verify-minio
```

Or manually (use `https://` when `minio.tls: true`):
```bash
curl -s http://<MINIO_HOST>:9000/minio/health/live   # Expected: HTTP 200
```

---

## Step 3 — Bootstrap Bucket and IAM

The `mcli` (MinIO Client) binary must be installed on the controller host. If
`mcli --version` fails, install the MinIO client from its official distribution
before continuing.

Ensure `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD` are filled in `.envrc`
(`MINIO_ENDPOINT` is already generated by `make configure`), then run the
bootstrap script for your environment:

```bash
bash components/minio/bootstrap.sh <ENV>
# e.g.: bash components/minio/bootstrap.sh sandbox
#        bash components/minio/bootstrap.sh production
```

Or via Make (picks up `ENV` from `.env.mk`):
```bash
make bootstrap-minio          # sandbox (default)
make bootstrap-minio ENV=production
```

The script creates:
- One bucket: `tfstate-<ENV>`
- One IAM policy: `terraform-<ENV>-policy` (scoped to `tfstate-<ENV>` only)
- One IAM user: `terraform-<ENV>-<random>` bound to the above policy

The script **writes the scoped credentials directly into `.envrc`** (via
`scripts/loop/envrc-upsert.py`) — `MINIO_ACCESS_KEY` (access key id
`terraform-<ENV>-<generated>`) and `MINIO_SECRET_KEY`. No manual copy is needed;
the secret value is not printed. `.envrc` is gitignored and blocked by the
pre-commit guard. Run `direnv allow` if you are in an interactive shell and the
values are not yet exported (loop scripts source `.envrc` directly).

Then initialize Terraform:
```bash
make init ENV=<ENV> && make plan ENV=<ENV>
```

---

## Future Migration to GitLab HTTP Backend

When ready to adopt GitLab:

1. Pull current state: `terraform state pull > backup.tfstate`
2. Replace the `backend "s3"` block in `backend.tf` with:
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
