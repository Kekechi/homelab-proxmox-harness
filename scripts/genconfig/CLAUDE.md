# scripts/genconfig/ — config generator (split package)

`generate-configs.py` is a thin shim; the implementation lives here, split per
the decided **per-output-artifact** boundary (per-domain was rejected because
`gen_inventory` has cross-service derivations a service split would shatter).
Don't read the whole package to make a small change — use the routing table.

## File → responsibility

| File | Holds |
|---|---|
| `main.py` | CLI entry (`main`, `--examples`), the write-orchestration sequence, and the public symbol re-export surface the shim + test harnesses rely on |
| `config.py` | `REPO_ROOT`, `CHANGE_ME`, `load_config` (deep-merges `config/<env>.local.yml`), `is_inside_container` |
| `discovery.py` | component discovery (`components/` + `components.local/`, collision = error), manifest validation, `instance_tf_key`/`instance_group`/`instance_config` |
| `capabilities.py` | consumes/provides resolution (`build_providers`, `resolve_consumes`, `CORE_CONSUMES`), re-convergence reporting |
| `helpers.py` | shared primitives: `_hcl_str` (null-if-empty), `_strip_prefix`, `resolve_network`, `_derive_dns_records`, `validate_cidr`, `validate_domain_name`, `atomic_write` (`.envrc` smart-merge, never deletes unknown keys), `write_file`, `_envrc_secret_vars` (derived from manifests) |
| `validation.py` | `validate_schema` and the Nexus repo validators (`validate_nexus_apt_proxy_repos`, `validate_nexus_raw_hosted_repos`, `_NEXUS_REQUIRED_APT_REPOS`) |
| `emit/tfvars.py` | `gen_tfvars` → `terraform/<env>.tfvars` |
| `emit/inventory.py` | `gen_inventory` → `ansible/inventory/hosts.yml` (groups from manifests; capability vars injected) |
| `emit/envrc.py` | `gen_envrc` → `.envrc` non-secret portion |
| `emit/env_mk.py` | `gen_env_mk` → `.env.mk` |
| `emit/pki_group_vars.py` | `gen_pki_group_vars` → `group_vars/pki_*` |
| `emit/ansible_cfg.py` | `gen_ansible_cfg` → `ansible/ansible.cfg` (agent-host facts from config `agent:`) |
| `emit/config_example.py` | `gen_config_example` → `config/<env>.yml.example` (core skeleton + component fragments) |

## Task → file

| Task | Edit |
|---|---|
| Change a tfvars value | `emit/tfvars.py` |
| Change an inventory group / group_var | `emit/inventory.py` |
| Change a non-secret `.envrc` line | `emit/envrc.py` (per-component sections come from manifest `env:` blocks) |
| Change `.env.mk` | `emit/env_mk.py` |
| Change PKI root/issuing group_vars | `emit/pki_group_vars.py` |
| Add a validation rule | `validation.py` (generic checks) or the component's manifest `config.required` |
| Add/lookup a component or capability | `discovery.py` / `capabilities.py` + the component's `component.yml` |
| DNS A-record / `/etc/hosts` derivation | `helpers._derive_dns_records` (shared) |
| Shared HCL/IP helpers | `helpers.py` |

## Cross-component values — capability resolution

Cross-component reaches are GONE from the emitters: values arrive via each
manifest's `consumes:` (resolved in `capabilities.py`) — e.g.
`otelcol_minio_endpoint` ← `s3.endpoint`, `dns_collector_syslog_endpoint` ←
`syslog.target`, `dns_records` ← `dns.record` (many), all.vars'
`nexus_apt_proxy`/`common_log_server_address` ← `CORE_CONSUMES`.
`emit/inventory.py`'s `_self_vars` holds only own-config vars (TLS flags,
FQDNs, the dnsdist ACL). `_derive_dns_records` (helpers) still feeds both the
/etc/hosts mesh and the implicit `dns.record` providers — enabled components
only.

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
