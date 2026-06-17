# scripts/ — config generator & deployment-loop tooling

Progressive-disclosure guide for agents working under `scripts/`. The two
substantial things here are the **config generator** (`generate-configs.py`) and
the **destroy→rebuild loop** (`loop/`). Don't read the whole generator to make a
small change — use the routing table.

## generate-configs.py — task → function routing

Single source of truth is `config/<env>.yml`; this script renders all generated
artifacts. ~1100 lines; jump to the function for your task:

| Task | Function (current single file) | Emits |
|---|---|---|
| Change a `terraform/<env>.tfvars` value | `gen_tfvars` | tfvars |
| Change an Ansible inventory group / group_var | `gen_inventory` | inventory/hosts.yml |
| Change the Squid allowlist | `gen_allowed_cidrs` | allowed-cidrs.conf |
| Change a non-secret `.envrc` line | `gen_envrc` | .envrc (smart-merge in `atomic_write`) |
| Change `.env.mk` (ENV/bucket) | `gen_env_mk` | .env.mk |
| Change PKI root/issuing group_vars | `gen_pki_group_vars` | group_vars/pki_* |
| Add a validation rule | `validate_schema` (+ `validate_nexus_*`) | — |
| DNS A-record / `/etc/hosts` derivation | `_derive_dns_records` (shared) | inventory |
| Shared HCL/IP helpers | `_hcl_str` (null-if-empty), `_strip_prefix`, `resolve_network` | — |

Rules of the road (do NOT duplicate — see `.claude/rules/config-management.md`):
- Emit optional/empty scalars with `_hcl_str` (→ HCL `null`, never `""`).
- Generated files carry a DO-NOT-EDIT header; never hand-edit them.
- Output must be **byte-stable** for unchanged input — the golden test enforces it.

## Cross-service couplings that must stay in one pass (`gen_inventory`)

- `log_server` reads `services.minio` (→ `otelcol_minio_endpoint`) and
  `services.splunk` (→ `otelcol_splunk_hec_enabled`/`_url`, true only when Splunk
  is enabled — Splunk is deprecation-planned; default sink is MinIO awss3).
- `dns.dist` reads its network CIDR + `client_cidrs` (→ `pdns_dnsdist_acl_cidrs`).
- `_derive_dns_records` feeds both `common_internal_hosts` (/etc/hosts) and the
  `dns_auth` A-records.

## Adding to the config — the two cases

- **Case A — new field on an existing service**: add it to `config/<env>.yml.example`,
  read it in the relevant `gen_*`, emit via `_hcl_str` if optional, then
  `python3 scripts/test-golden.py --update` and review `git diff scripts/golden/`.
- **Case B — new service**: add `services.<name>` (ip/node/network/...), extend
  `validate_schema`, add emission to `gen_tfvars` (TF vars + `enable_<svc>`) and
  `gen_inventory` (auto-derived group), add the TF module + Ansible role/playbook.
  The loop is the regression test; the golden fixture in `test-golden.py` should
  gain the new service.

## Tests

- `test-golden.py` — golden-output regression for every emitter against one
  complete synthetic fixture (no secrets). Run it after any generator change;
  `--update` rewrites the baselines under `scripts/golden/` (review the diff).
- `test-generator.py` — older unit tests; some fixtures are stale (predate the
  per-service `node` requirement) and need refreshing.

## Planned modularization (decided boundary — not yet split)

Target layout (per-output-artifact; per-domain rejected because `gen_inventory`
has cross-service derivations that a service split would shatter):

```
scripts/genconfig/
  main.py config.py helpers.py validation.py
  emit/{tfvars,inventory,allowed_cidrs,envrc,env_mk,pki_group_vars}.py
```

`generate-configs.py` becomes a thin shim importing `genconfig.main`. The
golden test is the acceptance gate: the split is correct iff `test-golden.py`
still passes byte-identically. Co-locate a `genconfig/CLAUDE.md` (this routing
table) and an `emit/CLAUDE.md` (shared emitter contract: DO-NOT-EDIT header,
byte-stability) when splitting.

## Known generator cleanups (low priority)

- **D5**: syslog ports (1515 DNS, 1516 auth) are duplicated across the
  `otelcol`, `dns_collector`, and `common` role defaults rather than emitted
  from one config field. Values are consistent today; unify via a generated
  group_var when touched.

## loop/ — destroy→rebuild verification harness

See `docs/design/deployment-automation-overhaul.md` and the loop scripts'
headers. `make loop-teardown|loop-minio|loop-secrets`; `scripts/loop/run.sh`
drives a full cycle. Sandbox only; teardown preserves qemu VMs by default
(the token cannot re-clone them — they are operator-managed prereqs).
