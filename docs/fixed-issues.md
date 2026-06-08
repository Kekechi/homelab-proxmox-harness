# Fixed Issues

## dns-collector install not idempotent
**Fixed:** 2026-06-08

Three bugs in `ansible/roles/dns_collector/tasks/install.yml`:
1. `stat` path used `dns-collector` (hyphenated) — binary is named `dnscollector`
2. Version check used `--version` — Go binary uses single-dash `-version`
3. Wrong flag caused rc=1 with empty stdout → `_dns_collector_installed` always false

Note: Go binaries commonly use single-dash flags. Verify with `ansible <host> -m shell -a "<binary> -help 2>&1"` before writing version check tasks.
