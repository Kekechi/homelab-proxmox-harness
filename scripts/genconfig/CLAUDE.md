# scripts/genconfig/ — config generator (split package)

`generate-configs.py` is a thin shim; the implementation lives here, split per
the decided **per-output-artifact** boundary (per-domain was rejected because
`gen_inventory` has cross-service derivations a service split would shatter).
Don't read the whole package to make a small change — use the routing table.

## File → responsibility

| File | Holds |
|---|---|
| `main.py` | CLI entry (`main`), the write-orchestration sequence, and the public symbol re-export surface the shim + test harnesses rely on |
| `config.py` | `REPO_ROOT`, `CHANGE_ME`, `load_config`, `is_inside_container` |
| `helpers.py` | shared primitives: `_hcl_str` (null-if-empty), `_strip_prefix`, `resolve_network`, `_derive_dns_records`, `validate_cidr`, `validate_domain_name`, `atomic_write` (`.envrc` smart-merge), `write_file`, `_ENVRC_SECRET_VARS` |
| `validation.py` | `validate_schema` and the Nexus repo validators (`validate_nexus_apt_proxy_repos`, `validate_nexus_raw_hosted_repos`, `_NEXUS_REQUIRED_APT_REPOS`) |
| `emit/tfvars.py` | `gen_tfvars` → `terraform/<env>.tfvars` |
| `emit/inventory.py` | `gen_inventory` → `ansible/inventory/hosts.yml` (**all cross-service derivations live here**) |
| `emit/allowed_cidrs.py` | `gen_allowed_cidrs` → Squid allowlist |
| `emit/envrc.py` | `gen_envrc` → `.envrc` non-secret portion |
| `emit/env_mk.py` | `gen_env_mk` → `.env.mk` |
| `emit/pki_group_vars.py` | `gen_pki_group_vars` → `group_vars/pki_*` |

## Task → file

| Task | Edit |
|---|---|
| Change a tfvars value | `emit/tfvars.py` |
| Change an inventory group / group_var | `emit/inventory.py` |
| Change the Squid allowlist | `emit/allowed_cidrs.py` |
| Change a non-secret `.envrc` line | `emit/envrc.py` (secret list → `helpers._ENVRC_SECRET_VARS`) |
| Change `.env.mk` | `emit/env_mk.py` |
| Change PKI root/issuing group_vars | `emit/pki_group_vars.py` |
| Add a validation rule | `validation.py` |
| DNS A-record / `/etc/hosts` derivation | `helpers._derive_dns_records` (shared) |
| Shared HCL/IP helpers | `helpers.py` |

## Cross-service couplings — must stay in one pass (`emit/inventory.py`)

- `log_server` reads `services.minio` (→ `otelcol_minio_endpoint`) and
  `services.splunk` (→ `otelcol_splunk_hec_enabled`/`_url`, true only when Splunk
  is enabled — Splunk is deprecation-planned; default sink is MinIO awss3).
- `dns.dist` reads its network CIDR + `client_cidrs` (→ `pdns_dnsdist_acl_cidrs`)
  and `services.log_server.ip` (→ `dns_collector_syslog_endpoint` + dnstap).
- `_derive_dns_records` feeds both `common_internal_hosts` (/etc/hosts) and the
  `dns_auth` A-records.

## The public surface is a contract

`main.py` re-exports every emitter, validator, and helper the test harnesses
reach via `gen.<name>` (they load `generate-configs.py` by path). If you add a
new top-level callable a test references, add it to `main.py`'s imports and
`__all__`.

## Tests

- `python3 scripts/test-golden.py` — byte-identical golden gate. Run after ANY
  change here. `--update` rewrites baselines (review `git diff scripts/golden/`)
  — only when you intend to change emitted output.
- `python3 scripts/test-generator.py` — older unit tests; some fixtures are
  stale (predate the per-service `node` requirement) and fail independent of
  this package.

## Adding to the config — the two cases

- **Case A — new field on an existing service**: add it to
  `config/<env>.yml.example`, read it in the relevant `emit/*` (or `helpers`),
  emit via `_hcl_str` if optional, then `test-golden.py --update` and review.
- **Case B — new service**: add `services.<name>`, extend `validate_schema`
  (`validation.py`), add emission to `emit/tfvars.py` (TF vars + `enable_<svc>`)
  and `emit/inventory.py` (auto-derived group), add the TF module + Ansible
  role/playbook. The golden fixture in `test-golden.py` should gain the service.
