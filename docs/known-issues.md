# Know Issues
## apt package TLS migration dependency
APT debian source and auth gets updated in ansible common role.
Specific apt packages such as step-ca, dns-dist, dns-auth does not get updated during common, so fails `apt update`.

The underlying issue is a chicken-and-egg between CA trust and apt: `apt-get update` needs the root CA trusted to reach Nexus HTTPS, but trusting the root CA requires `ca-certificates` to be installed first. Any host provisioned before Nexus switched to HTTPS keeps stale HTTP source files and cannot bootstrap itself out of the loop via Ansible alone.

**Temporary mitigations applied 2026-06-08:**
- Root CA SCPed directly to blocked hosts and `update-ca-certificates` run out-of-band
- Stale `http://` source files patched in-place on affected hosts (pdns, smallstep sources)
- `debian-nexus.sources` removed from Ubuntu host (splunk-server); `ansible_distribution == 'Debian'` guard added to common role to prevent redeployment

**The `ansible_distribution == 'Debian'` guard in the common role is a stopgap** — Ubuntu hosts now bypass Nexus entirely. Must be revisited when Ubuntu Nexus proxy sources are added.

**Proper fix:** Refactor common role and all roles with Nexus-proxied apt sources (pdns_auth_recursor, step_ca_common, step_client) into: (1) bootstrap apt via plain HTTP, (2) deploy and activate root CA, (3) switch sources to HTTPS Nexus. Requires component-by-component dependency mapping across all affected roles.

## Nexus TLS does not update itself


## Hosts mesh distributes the full internal host map to every managed host

The generator-emitted `/etc/hosts` mesh (`common_internal_hosts`) writes every
enabled service's name→address mapping onto every managed host, so each host
knows where all infrastructure lives. Within a single trust zone this is
acceptable — the internal DNS zone exposes the same information, the mesh just
makes it explicit and locally persistent — but it is an information-disclosure
consideration, not a bug-free default (operator-reviewed 2026-08).

If a future component lives in a different trust zone that should NOT learn the
infra layout, the mesh (and the DNS zone view) will need scoping — e.g. a
per-zone mesh subset or a `mesh: false`-style per-service exclusion, analogous
to the existing `dns: false`. Revisit when the first cross-zone component
appears; no action needed while all services share one segment.
