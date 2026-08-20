# components/ — one directory owns one service

Authoritative design: `docs/design/component-architecture.md`. A component owns
its vertical slice; the core (terraform/, scripts/genconfig/, Makefile) is
generic and DISCOVERS components — adding a service never touches central files.

## Anatomy

```
components/<name>/
  component.yml            manifest — the single source of truth (below)
  config.example.yml.in    config fragment (assembled into config/*.yml.example
                           by `make examples`; @DOMAIN@/@NETWORK@ placeholders)
  playbook.yml             ansible entrypoint (make ansible-<name>); roles
                           resolve from the adjacent roles/ dir + core roles_path
  roles/<role>/            this component's roles (prefix vars <role>_*)
  verify.sh                Tier-1 behavioral verify — discovered by verify-all
  collect.sh               Tier-2 raw state dump — discovered by collect-all
  bootstrap.sh             kind:none only — out-of-band provisioning entrypoint
```

`components.local/` (gitignored) uses the identical layout for PRIVATE
components — discovered through the same code path; instance values go in
`config/<env>.local.yml` (gitignored, deep-merged). A name or tf_key collision
with a public component is a hard error, never a silent shadow.

## The manifest (component.yml)

See `scripts/genconfig/discovery.py` docstring for the full field reference.
Key rules:

- `instances.<i>.kind`: `vm` | `lxc` (Terraform-managed via the generic
  for_each) or `none` (out-of-TF-graph, provisioned by `bootstrap:`).
- `tf_key` is the Terraform state-address key (`module.vm|lxc["<tf_key>"]`) —
  NEVER change it on an existing instance without a moved{} block; `group` is
  the inventory group. Defaults: component name (single instance) /
  `<component>_<instance>` (multi).
- `resources`/`options` carry sizing and lifecycle defaults; per-env override
  via `services.<name>.resources` in config.
- `config.required` is validated only when the component is enabled
  (`services.<name>.enabled: true`); `config.defaults` fill omitted optionals.

## Capabilities — dependencies are contracts, never names

- `provides`: what this instance offers (value templates over its own config —
  `{ip}`, `{port}`, `{domain}`, `{scheme}`, `{host}`; `value_tls` variant).
- `consumes`: `var_name → {capability, optional?, many?, priority?, also_set?}`.
  Resolved values land in the instance's inventory group vars. Optional +
  unresolved ⇒ the var DOES NOT EXIST (roles gate on defaults / `is defined`).
- Every enabled instance with an `ip` implicitly provides `dns.record`
  (honouring `dns:`, `dns_name:`, `dns_aliases:`); the dns component consumes
  it `many: true`. Stale zone records are WARNED about by default (prod zones
  carry hand edits); pass `-e dns_records_prune=true` to reconcile by deletion
  — the sandbox rebuild loop does, and private-component teardown should.
- Current capability set: `s3.endpoint`, `ca.url`, `apt.source`,
  `syslog.target`, `splunk.hec`, `dns.resolver`, `dns.record`.
- When a provider set changes, `make configure` prints the stale-consumer
  re-run list (re-convergence is computed, not tribal memory).

## Behavioral extension (three rules)

1. Disjoint ownership needs no seam — files/daemons no public component
   manages are wholly owned by the extending component (its play may target
   `hosts: all`).
2. Touching public-owned surface requires a DECLARED seam (`seam:` in the
   owner's manifest) — daemon-native include dirs preferred (sshd_config.d,
   nginx conf.d, sudoers.d, systemd drop-ins, admin APIs).
3. Templating over another component's managed base file is never allowed.

## Checklist for a new component

1. `mkdir components/<name>` (or `components.local/<name>` for private) with
   `component.yml` + `config.example.yml.in` + `playbook.yml` + `verify.sh`.
2. Add the `services.<name>:` block to `config/<env>.yml` (or `<env>.local.yml`)
   with `enabled: true`.
3. `make configure` → review tfvars/inventory diffs and any re-converge list.
4. `make plan` / `make apply` (sandbox; plan-file rule holds), then
   `make ansible-<name>`, then `make verify-<name>` / `make verify-all`.
5. Public components only: `make examples` and commit the assembled examples.
