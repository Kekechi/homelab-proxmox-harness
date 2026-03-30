# Network Policy

## Architecture

The dev container runs on a Docker network with `internal: true`, which means it has
**no direct internet or LAN access**. All outbound traffic must pass through the
Squid forward proxy, which enforces an allowlist.

```
[WSL2 host] ──── full LAN + internet access
      │
      │  Docker
      ▼
[squid-proxy container]
  ├── internal network (shared with devcontainer)
  └── external network (bridge to WSL2 → LAN)
        │
        │  ACL allowlist:
        │   ✓ Sandbox Proxmox VLAN CIDR
        │   ✓ MinIO LXC IP:9000
        │   ✓ registry.terraform.io
        │   ✓ releases.hashicorp.com
        │   ✓ github.com
        │   ✓ objects.githubusercontent.com
        │   ✓ CONNECT port 22 → sandbox CIDR (Ansible SSH)
        │   ✗ everything else
        ▼
[devcontainer]
  └── isolated network only (internal:true)
      http_proxy → squid-proxy:3128
```

---

## Squid Config Files

Both files are baked into the Squid Docker image at build time and are **not** accessible
as writable files from the workspace. To update them:

1. Edit `.devcontainer/squid/allowed-cidrs.conf` or `.devcontainer/squid/squid.conf`
2. Run `docker compose build squid-proxy` (or `make build`)
3. Reopen the dev container

### `allowed-cidrs.conf`

One CIDR or IP per line. Controls which LAN addresses the devcontainer can reach:
```
192.168.20.0/24   # Sandbox Proxmox VLAN
192.168.20.5/32   # MinIO LXC
```

### `squid.conf`

Controls allowed domains and ports. Domains use exact matching (no wildcards):
```squid
acl allowed_domains dstdomain registry.terraform.io
acl allowed_domains dstdomain releases.hashicorp.com
acl allowed_domains dstdomain github.com
acl allowed_domains dstdomain objects.githubusercontent.com
```

---

## Ansible SSH Through Squid

Squid allows `CONNECT` on port 22 to addresses in `allowed_cidrs`. Ansible uses
`ncat` as a ProxyCommand to tunnel SSH through Squid:

```ini
# ansible/ansible.cfg
[ssh_connection]
ssh_args = -o ProxyCommand="ncat --proxy squid-proxy:3128 --proxy-type http %h %p"
```

This means:
- Ansible can SSH to sandbox VMs at IPs within the allowed CIDR
- Ansible CANNOT SSH to production VMs or arbitrary internet hosts
- SSH to any non-allowed IP is denied by Squid's ACL

---

## MinIO Through Squid

MinIO is on the Proxmox LAN (not in Docker). The devcontainer has no direct LAN access,
so Terraform S3 backend calls go through Squid:

```
Terraform → http_proxy → squid-proxy:3128 → MinIO @ 192.168.X.X:9000
```

Terraform's S3 backend respects `http_proxy` automatically. The `no_proxy` env var
intentionally does NOT include the MinIO IP — all MinIO traffic must go through Squid.

Other devices on the LAN access MinIO directly and are unaffected by Squid.

---

## WSL2 Networking Notes

The `internal:true` Docker network behaviour on WSL2 depends on the networking mode:

- **NAT mode (default):** `internal:true` works correctly — devcontainer cannot route to LAN directly.
- **Mirrored mode:** Behaviour differs. Do NOT use mirrored networking with this setup.

Check your WSL2 networking mode:
```bash
# On Windows, in %USERPROFILE%\.wslconfig:
[wsl2]
networkingMode=NAT   # ensure this is NAT, not mirrored
```

Run `make verify-isolation` after rebuilding the dev container to confirm isolation is active.

---

## Reconfiguring for a Different Network Topology

| What changed | Files to update | Command |
|---|---|---|
| Sandbox VLAN CIDR | `.devcontainer/squid/allowed-cidrs.conf` | `make build` |
| MinIO IP | `.devcontainer/squid/allowed-cidrs.conf` | `make build` |
| Add allowed domain | `.devcontainer/squid/squid.conf` | `make build` |
| MinIO endpoint URL | `.envrc` | `direnv allow` |
| Proxmox API URL | `.envrc` | `direnv allow` |
| Proxmox API token | `.envrc` | `direnv allow` |
| Terraform structural config | `terraform/sandbox.tfvars` or `terraform/production.tfvars` | `terraform init` |
