---
paths:
  - "ansible/**"
  - "components/*/playbook.yml"
  - "components/*/roles/**"
---

# Ansible Workflow Rules

## Running plays

- `ansible/ansible.cfg` is GENERATED from the `agent:` section of `config/<env>.yml`
  (SSH key path, extra ssh args) — NEVER hand-edit it; run `make configure` instead
- Deploy one component with `make ansible-<component>` — it resolves
  `components/<name>/playbook.yml` (or `components.local/<name>/`) and runs it from
  `ansible/` so the generated cfg and inventory apply; roles resolve adjacent to the
  playbook
- The common baseline for all hosts is `make ansible-env` (`ansible/playbooks/site.yml`)
- If invoking `ansible-playbook` directly, run it from `ansible/` (or set
  `ANSIBLE_CONFIG=ansible/ansible.cfg`) — without the cfg, the inventory, key, and SSH
  settings are wrong

## Playbook Conventions

- Use FQCN (fully qualified collection names): `ansible.builtin.copy`, not `copy`
- No hardcoded IPs in roles — use inventory variables or role defaults
- Component roles live in `components/<name>/roles/`; `ansible/roles/` holds genuinely
  shared roles only (`common`, `step_client`)
- Always run `ansible-lint` before committing playbook changes (`make ansible-lint`
  covers core playbooks + every component)

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

A single `ansible/inventory/hosts.yml` is generated from `config/<env>.yml` by
`make configure` — enabled components get auto-derived groups; ad-hoc hosts come from
the `hosts:` section. NEVER edit it directly.

To bring a new host under management:
1. Component instance → add its `services.<key>:` block to `config/<env>.yml`
2. Ad-hoc host → add it under `hosts.<group>.<hostname>.ansible_host`
3. Run `make configure` to regenerate the inventory

Target specific groups with `--limit` (e.g. `--limit minio`). BLOCK: never run without
`--limit` when production hosts are present in the inventory.
