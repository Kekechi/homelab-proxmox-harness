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

## Package Installation — Prefer OS Package Manager

When a tool offers multiple installation methods, prefer the OS package manager (APT on Debian) over downloading GitHub release tarballs, unless there is a specific reason not to.

**Default choice: APT**
- Use `ansible.builtin.apt` with an official vendor APT repo (DEB822 format, key in `/etc/apt/keyrings/`)
- Simpler tasks, automatic dependency resolution, `apt upgrade` handles future updates
- No URL format fragility across releases

**Use GitHub release tarball only when:**
- The tool has no APT repo or the APT repo lags significantly behind (check the GitHub issues)
- A specific version must be pinned that is not available via APT
- The target host has no internet access and binaries must be copied from the controller

**Do not use `apt_key` (deprecated)** — use `get_url` to `/etc/apt/keyrings/<tool>.asc` + DEB822 sources file.

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
