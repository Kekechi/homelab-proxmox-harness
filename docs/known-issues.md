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

