# scripts/ — config generator & deployment-loop tooling

Progressive-disclosure guide for agents working under `scripts/`. The two
substantial things here are the **config generator** (`generate-configs.py`) and
the **destroy→rebuild loop** (`loop/`). Don't read the whole generator to make a
small change — use the routing table.

## generate-configs.py — task → file routing

Single source of truth is `config/<env>.yml`; this renders all generated
artifacts. `generate-configs.py` is now a **thin shim** — the implementation is
split into `scripts/genconfig/` (per-output-artifact). Jump to the file for your
task (full routing table: `scripts/genconfig/CLAUDE.md`):

| Task | File / function | Emits |
|---|---|---|
| Change a `terraform/<env>.tfvars` value | `genconfig/emit/tfvars.py` (`gen_tfvars`) | tfvars |
| Change an Ansible inventory group / group_var | `genconfig/emit/inventory.py` (`gen_inventory`) | inventory/hosts.yml |
| Change a non-secret `.envrc` line | `genconfig/emit/envrc.py` (`gen_envrc`); smart-merge in `helpers.atomic_write` | .envrc |
| Change `.env.mk` (ENV/bucket) | `genconfig/emit/env_mk.py` (`gen_env_mk`) | .env.mk |
| Change PKI root/issuing group_vars | `genconfig/emit/pki_group_vars.py` (`gen_pki_group_vars`) | group_vars/pki_* |
| Add a validation rule | `genconfig/validation.py` (`validate_schema` + `validate_nexus_*`) | — |
| DNS A-record / `/etc/hosts` derivation | `genconfig/helpers.py` (`_derive_dns_records`, shared) | inventory |
| Shared HCL/IP helpers | `genconfig/helpers.py` (`_hcl_str` null-if-empty, `_strip_prefix`, `resolve_network`) | — |

Rules of the road (do NOT duplicate — see `.claude/rules/config-management.md`):
- Emit optional/empty scalars with `_hcl_str` (→ HCL `null`, never `""`).
- Generated files carry a DO-NOT-EDIT header; never hand-edit them.
- Output must be **byte-stable** for unchanged input — the golden test enforces it.

## Cross-component values

Resolved via capability contracts (`genconfig/capabilities.py`) from each
component manifest's consumes/provides — see `scripts/genconfig/CLAUDE.md` and
`components/CLAUDE.md`. The emitters no longer reach across services.

## Adding to the config — the two cases

- **Case A — new field on an existing service**: add it to `config/<env>.yml.example`,
  read it in the relevant `emit/*` (or `helpers.py`), emit via `_hcl_str` if
  optional, then `python3 scripts/test-golden.py --update` and review `git diff scripts/golden/`.
- **Case B — new service**: create `components/<name>/` (manifest + fragment +
  playbook + verify.sh) and add its `services.<name>:` block to config — no
  central-file edits. See `components/CLAUDE.md` for the checklist.

## Tests

- `test-golden.py` — golden-output regression for every emitter against one
  complete synthetic fixture (no secrets). Run it after any generator change;
  `--update` rewrites the baselines under `scripts/golden/` (review the diff).
- `test-generator.py` — unit tests (validation, tfvars map, inventory,
  capability resolution, .envrc smart-merge). Green as of the component
  refactor; keep it green.

## Modularization — DONE

The generator is split into `scripts/genconfig/` (per-output-artifact;
per-domain was rejected because the inventory emitter has cross-service
derivations that a service split would shatter):

```
scripts/genconfig/
  main.py config.py helpers.py validation.py
  emit/{tfvars,inventory,ansible_cfg,config_example,envrc,env_mk,pki_group_vars}.py
```

`generate-configs.py` is a thin shim importing `genconfig.main` (CLI + public
surface preserved exactly). Routing + the emitter contract are co-located:
`scripts/genconfig/CLAUDE.md` (function → file) and
`scripts/genconfig/emit/CLAUDE.md` (DO-NOT-EDIT header, byte-stability,
`_hcl_str` null-if-empty). The golden test is the acceptance gate — the split
preserved `test-golden.py` byte-identically.

## Known generator cleanups (low priority)

- **D5**: syslog ports (1515 DNS, 1516 auth) are duplicated across the
  `otelcol`, `dns_collector`, and `common` role defaults rather than emitted
  from one config field. Values are consistent today; unify via a generated
  group_var when touched.

## loop/ — destroy→rebuild verification harness

See `docs/design/deployment-automation-overhaul.md` and the loop scripts'
headers. `make loop-teardown|loop-minio|loop-secrets`; `scripts/loop/run.sh`
drives a full cycle. Sandbox only; teardown preserves qemu VMs by default as a
conservative choice (a full `--include-vms` wipe also destroys the offline root
CA and regenerates the whole trust chain). The token *can* re-clone the VM
templates (verified via an `--include-vms` cold rebuild) — the old "token cannot
clone" note was wrong; the real historical blocker was template storage/node-
locality. Pass `--include-vms` for a true cold start from nothing.
