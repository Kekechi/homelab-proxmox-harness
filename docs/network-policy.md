# Network Policy

Intent-level description of the network boundary around the IaC agent. This repository
is public — specific subnets, addresses, and vendor products are deliberately absent;
they live in `config/<env>.yml` (gitignored).

## Architecture

The agent (Claude Code) runs on a **dedicated controller host** provisioned by the
operator. The host's network position *is* the network boundary:

- It can reach the **sandbox segment**: the Proxmox API, sandbox instances (SSH), and
  the sandbox MinIO state backend.
- **Production segments are not routable from this host** by the operator's network
  design. The production MinIO instance and any production hosts are unreachable, and
  their credentials are never present on this host (see `docs/proxmox-iam.md`).
- Outbound internet egress is the host's own; there is no forward-proxy allowlist in
  front of the agent. Version pinning of providers and collections
  (`.terraform.lock.hcl`, `requirements.yml`) is correspondingly load-bearing — see
  `docs/threat-model.md`.

The previous architecture (containerized agent behind a deny-by-default forward proxy)
is retired; this host-based model trades the proxy layer for IAM-first enforcement plus
operator-managed segmentation.

## SSH

- `ansible/ansible.cfg` is **generated** from the `agent:` section of `config/<env>.yml`
  (key path, extra SSH args). There is no ProxyCommand; Ansible connects directly to
  hosts the controller can route to.
- Claude Code's own tool permissions deny raw `ssh`/`scp` in shell calls; the
  `sandbox-ssh`/`sandbox-scp` aliases exist so the agent's interactive SSH to sandbox
  hosts passes through that permission layer deliberately (see CLAUDE.md). This is a
  workflow control, not a network control.

## Reconfiguring

| What changed | Where to change it | Command |
|---|---|---|
| Sandbox network (bridge/CIDR/gateway) | `config/<env>.yml` → `infrastructure.networks` | `make configure` |
| MinIO endpoint | `config/<env>.yml` → the minio service block | `make configure`, then `direnv allow` |
| Proxmox API endpoint | `config/<env>.yml` → `infrastructure.proxmox` | `make configure`, then `direnv allow` |
| Agent SSH key / args | `config/<env>.yml` → `agent:` | `make configure` |
| Secrets (tokens, keys) | `.envrc` (manual) / `.envrc.local` | `direnv allow` |
