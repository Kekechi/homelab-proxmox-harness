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
- Inventory files are per-environment: `inventory/sandbox/hosts.yml`, `inventory/production/hosts.yml`
- Always run `ansible-lint` before committing playbook changes

## Collections

Collections are pinned in `requirements.yml`. Install with:
```
ansible-galaxy collection install -r ansible/requirements.yml
```

Do not add collections to `requirements.yml` without pinning a version.

## Inventory

Sandbox VM IPs come from `terraform output` after a successful apply. Update `inventory/sandbox/hosts.yml` with actual IPs — never hardcode in roles.
