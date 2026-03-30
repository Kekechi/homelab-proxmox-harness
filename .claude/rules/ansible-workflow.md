---
paths:
  - "ansible/**"
---

# Ansible Workflow Rules

## SSH Connectivity

- All SSH to sandbox VMs goes through Squid CONNECT (configured in `ansible.cfg`)
- Sandbox VM IPs must be within the CIDR in `.devcontainer/squid/allowed-cidrs.conf`
- SSH to production VMs or non-sandbox hosts is blocked by Squid

## Playbook Conventions

- Use FQCN (fully qualified collection names): `ansible.builtin.copy`, not `copy`
- No hardcoded IPs in roles — use inventory variables or role defaults
- Single inventory file `ansible/inventory/hosts.yml` is generated from `config/<env>.yml` — NEVER edit directly
- Always run `ansible-lint` before committing playbook changes

## Collections

Collections are pinned in `requirements.yml`. Install with:
```
ansible-galaxy collection install -r ansible/requirements.yml
```

Do not add collections to `requirements.yml` without pinning a version.

## Inventory

A single `ansible/inventory/hosts.yml` is generated from `config/<env>.yml` by `make configure`. NEVER edit it directly.

To add a VM after `terraform apply`:
1. Get its IP: `cd terraform && terraform output -json`
2. Add it to `config/<env>.yml` under `hosts.<group>.<hostname>.ansible_host`
3. Run `make configure` to regenerate the inventory

Target specific environments with `--limit`:
- `--limit sandbox` — only sandbox group hosts
- `--limit minio` — only minio group hosts
- BLOCK: never run without `--limit` when production hosts are present
