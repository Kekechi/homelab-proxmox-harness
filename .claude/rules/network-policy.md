---
paths:
  - ".devcontainer/**"
  - "ansible/**"
  - "docs/network-policy.md"
  - "docs/threat-model.md"
---

# Network Policy

## Dev Container Isolation

The dev container runs on a Docker `internal:true` network — it has zero direct internet or LAN access. All outbound HTTP/HTTPS must pass through the Squid forward proxy at `squid-proxy:3128`.

Environment variables in the container:
- `http_proxy=http://squid-proxy:3128`
- `https_proxy=http://squid-proxy:3128`
- `no_proxy=localhost,127.0.0.1` — MinIO is NOT in no_proxy; it routes through Squid

## Squid Allowlist

| Destination | Protocol | Purpose |
|---|---|---|
| Sandbox VLAN CIDR | HTTP/HTTPS | Proxmox API access |
| MinIO IP:9000 | HTTP | Terraform state backend |
| `registry.terraform.io` | HTTPS | Provider version resolution |
| `releases.hashicorp.com` | HTTPS | Provider binary downloads |
| `github.com` | HTTPS | bpg/proxmox releases |
| `objects.githubusercontent.com` | HTTPS | GitHub release assets |
| Sandbox CIDR port 22 (CONNECT) | TCP | Ansible SSH tunnel |
| Everything else | — | DENIED |

## Ansible SSH

Ansible SSH to sandbox VMs is tunneled through Squid CONNECT. This is configured in `ansible/ansible.cfg` via `ProxyCommand`. SSH to non-sandbox IPs (including production VMs) is blocked by Squid ACL.

For SSH to work: the VM's IP must be within the sandbox VLAN CIDR in `allowed-cidrs.conf`.

## Reconfiguring the Allowlist

Squid config is baked into the Docker image — changes to workspace files have no effect at runtime.

1. Edit `.devcontainer/squid/allowed-cidrs.conf` or `squid.conf`
2. Ask the operator to run `make build`
3. Reopen the dev container

Never attempt to modify Squid config during a session.
