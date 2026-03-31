# Threat Model

This document defines what the isolation architecture protects against and what it does not.

## What This Protects Against

### Claude Code reaching production Proxmox API

**Mechanism:** Two-layer enforcement.

1. **Network:** The devcontainer is on `internal:true` Docker network. Squid ACL only
   allows the sandbox VLAN CIDR — production Proxmox IPs are not in `allowed-cidrs.conf`.
   A request to the production Proxmox API is denied at the Squid layer before it reaches
   the network.

2. **IAM:** Claude's token (`terraform@pve!claude-sandbox`) has ACL only on `/pool/sandbox`.
   Even if the network restriction were somehow bypassed, the token would receive a
   403 Forbidden from the Proxmox API for any resource outside the sandbox pool.

### Claude Code accessing arbitrary internet

**Mechanism:** Squid allowlist. The devcontainer has no direct internet access.
All HTTP/HTTPS traffic goes through Squid, which denies anything not in the domain
or CIDR allowlist. Blocked: social media, exfiltration endpoints, package repos not
in the allowlist, etc.

### Claude Code reading or corrupting production Terraform state

**Mechanism:** MinIO IAM policy. Claude's MinIO access key is bound to a policy that
allows read/write only on the `tfstate-sandbox` bucket. It cannot list, read, or write
`tfstate-production`. The operator's MinIO admin key is held separately and never
appears in the devcontainer.

### Claude Code escalating Proxmox privileges

**Mechanism:** `privsep=1` on the token. The token cannot exceed the privileges of
the `terraform@pve` user. Since the user has no global privileges, the token cannot
either — even if a role with broader privileges were accidentally assigned at a
higher path.

The `TerraformSandbox` role excludes `Permissions.Modify` and `User.Modify`,
so Claude cannot create new tokens, modify roles, or grant itself broader access.

### Ansible SSH to non-sandbox hosts

**Mechanism:** Squid CONNECT. Port 22 CONNECT is allowed only to IPs in
`allowed_cidrs`. SSH to production VMs or arbitrary internet hosts is denied
by Squid before the connection is established.

---

## What This Does NOT Protect Against

### Claude Code modifying `.devcontainer/` config files

Claude Code has write access to the entire workspace mount, including
`.devcontainer/squid/allowed-cidrs.conf` and `.devcontainer/squid/squid.conf`.

**Mitigations:**
- These files are baked into the Squid Docker image at build time. Modifying them
  in the workspace has no effect on the running proxy.
- Changes only take effect after the operator runs `docker compose build squid-proxy`
  and rebuilds the dev container. The operator reviews `git diff .devcontainer/`
  before rebuilding.
- CLAUDE.md explicitly prohibits modifying `.devcontainer/` files.
- A pre-commit hook flags changes to `.devcontainer/` for operator review.
- Both containers run with `cap_drop: ALL`, preventing a rogue process from adding
  its own iptables rules or modifying network configuration from inside the container.

**Residual risk:** If an operator rebuilds without reviewing the diff, modified Squid
config could expand network access.

### State corruption from concurrent sandbox applies

Terraform's S3 backend with MinIO does not support state locking (MinIO lacks DynamoDB
compatibility). If Claude Code and the operator both run `terraform apply` against
the sandbox simultaneously, state corruption is possible.

**Mitigation:** Claude Code always uses the plan-file workflow
(`terraform plan -out=sandbox.tfplan` → `terraform apply sandbox.tfplan`), which
reduces the apply window. Coordinate with the operator before applying.

### DNS information leaks

Docker containers on `internal:true` networks can still use Docker's embedded DNS
(127.0.0.11) to resolve arbitrary hostnames. Claude Code can resolve `production-host.local`
to an IP even though it cannot connect to it.

**Impact:** Information leak only, not a bypass vector. Network connections to resolved
IPs still fail at Squid.

### Claude Code reading files in the workspace mount

The devcontainer can read any file in the workspace (`/workspace`). This includes
`.envrc.example` and any documentation. It cannot read the host filesystem outside
the workspace mount.

**Mitigation:** The actual `.envrc` (with secrets) is gitignored and mounted at
the workspace root only if the operator has populated it on the host. The Squid config
with actual CIDRs is baked into the image, not a file in the workspace.

### Supply chain attacks via Terraform providers or Ansible collections

The Squid allowlist permits downloads from `github.com` and `releases.hashicorp.com`.
A compromised provider or collection could execute arbitrary code inside the container.

**Mitigation:** Pin provider versions in `versions.tf` and commit `.terraform.lock.hcl`.
Pin Ansible collection versions in `requirements.yml`. Review changelogs before upgrading.

---

## Isolation Strength Summary

| Threat | Layer 1 | Layer 2 | Protected? |
|---|---|---|---|
| Reach production Proxmox | Network (Squid ACL) | IAM (token ACL) | Yes — dual layer |
| Access arbitrary internet | Network (internal:true + Squid) | — | Yes |
| Read production state | MinIO IAM policy | — | Yes |
| Escalate Proxmox privileges | privsep=1 | Role excludes Permissions.Modify | Yes |
| Modify Squid config | Files baked into image | Operator review before rebuild | Partial |
| Concurrent apply | Plan-file workflow | Operator coordination | Partial |
| DNS resolution of private hosts | — | — | No (information only) |
