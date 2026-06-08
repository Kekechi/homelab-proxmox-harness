# Know Issues
## apt package TLS migration dependency
APT debian source and auth gets updated in ansible common role\
Specific apt packages such as step-ca, dns-dist, dns-auth does not get updated during common, so fails `apt update`\

## Nexus TLS does not update itself

## dns-collector install is not idempotent
The `stat` check in `ansible/roles/dns_collector/tasks/install.yml` looks for a file named `dns-collector` (hyphenated), but the installed binary is named `dnscollector` (no hyphen). As a result `_dns_collector_installed` is always false and the tarball download, extract, chmod, and cleanup tasks fire on every run even when the correct version is already installed. No functional impact — the correct binary ends up in place — but each run re-downloads the release tarball unnecessarily.