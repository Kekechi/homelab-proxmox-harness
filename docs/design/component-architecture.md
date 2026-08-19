# Design: Component/Plugin Architecture for the IaC Harness

_Status: **agreed with operator, 2026-08-19** — supersedes the "Target structure" sketch
in the operator's project note. Gate artifact before implementation ("structure-today vs
target-structure"). Public repo: intent-level only; no environment specifics here._

---

## 1. Problem — structure today

The Terraform primitives (`terraform/modules/proxmox-vm|proxmox-lxc|proxmox-network`) are
already generic. The coupling lives in the wiring layer above them. Knowledge about each
service is smeared **horizontally** across every layer; adding one service touches
~10–12 files, ~6 of them central:

| Layer | Per-service coupling today |
|---|---|
| `config/<env>.yml` | bespoke sub-schema per service (`pki` has children, `minio` has bare `ip`, …) |
| `scripts/genconfig/validation.py` | hardcoded required-key checks per service |
| `scripts/genconfig/emit/*.py` | per-service branches in every emitter; `inventory.py` has an `if svc == "minio" / elif …` ladder **and** cross-service reaches (log_server reads minio's IP, dns_dist reads log_server's IP) |
| `terraform/main.tf` | 7 hand-written `module "x"` blocks, ~25 args each, `count = var.enable_x ? 1 : 0` |
| `terraform/variables.tf` | **50 variables**: 7× `x_node`, 7× `x_ipv4_address`, 7× `x_ipv4_gateway`, 7× `x_*_id`, 6× `x_bridge`, 5× `enable_x`, ~11 shared |
| `terraform/outputs.tf` | per-service outputs (same disease) |
| `ansible/` | role + `playbooks/x-setup.yml` per service; `site.yml` hand-ordered |
| `scripts/verify/`, `scripts/collect/` | `verify-x.sh` / `collect-x.sh` plus `-all.sh` aggregators that hardcode the list |
| `Makefile` | per-service targets (`ansible-x`, `verify-x`) |
| `scripts/golden/` | fixtures pin all emitter output |

Observed consequences (live evidence from sandbox standup, 2026-08-19):
- A deployment with **one** service enabled still emitted ~40 flat `x_*` tfvars, and every
  disabled service needed node/IP/ID values just to pass validation.
- `make configure` silently deleted an operator-added key from `.envrc` (the smart-merge
  keeps only keys the template knows). The clobber problem reaches the secrets file.
- MinIO is out of the TF graph (state backend, bootstrapped out-of-band) and every emitter
  special-cases it by name.
- Placeholder sentinel (`CHANGE_ME`) is an undeclared contract between emitter, secret
  generator, and human; a differing hand-written sentinel nearly shipped as a real password.

## 2. Intent

1. **Adding a component must not touch central files.** Make the knowledge vertical: one
   directory owns one component; the core becomes generic and stable.
2. **Private, no-fork extension** (the actual driver). Private components must live outside
   the committed tree and still be first-class — the repo is public.
3. **Generated output must coexist with hand administration.** "Managed by generator" and
   "hand-edited" coexist in every file/daemon that needs both, by design.

Secondary: the harness (`.claude/`, `ansible.cfg`, loop scripts, guides) encodes the old
wiring *and* the old dev environment; it is rewritten **after** the structure lands, against
the new shape, on its own branch.

Non-negotiables preserved throughout: sandbox/production split, pool-scoped credentials,
plan-file gate, no secrets in tree, golden tests as the generator's correctness oracle.

## 3. Target structure

```
components/                    # public components, one dir each
  <name>/
    component.yml              # manifest — single source of truth (see §4)
    config.example.yml         # this component's config fragment (schema-by-example)
    roles/<role>/              # its ansible role(s)
    playbook.yml               # entrypoint play
    verify.sh                  # was scripts/verify/verify-<name>.sh
    collect.sh
    README.md                  # per-component design/ops notes
components.local/              # GITIGNORED; identical layout; private components
                               # discovered through the exact same code path
core (terraform/, scripts/genconfig/, ansible/, Makefile):
  terraform/main.tf            # TWO for_each module blocks (kind == vm | lxc)
  terraform/variables.tf       # ~10 shared vars + one typed `services` map
  terraform/outputs.tf         # one map output keyed by instance
  terraform/modules/…          # primitive modules with NORMALIZED interfaces
  scripts/genconfig/           # generic engine: discover → merge → validate → emit
  ansible/roles/               # genuinely shared roles only (common, otelcol)
  ansible/ansible.cfg          # GENERATED (agent-host facts come from config)
  Makefile                     # pattern rules: ansible-%, verify-%, collect-%
config/<env>.yml               # instance values, as today
config/<env>.local.yml         # gitignored overlay for private component values
.envrc                         # generated; sources .envrc.local (never templated)
scripts/golden/                # oracle, unchanged mechanism
docs/design/                   # cross-cutting designs only; per-component notes move
                               # into the component dir
```

Name-collision between `components/` and `components.local/` is a **hard error**, never a
silent shadow.

## 4. The manifest (`component.yml`)

```yaml
name: <component>
instances:                     # one component may own several boxes (e.g. a CA pair)
  <instance>:
    kind: lxc                  # vm | lxc | none  (none = out-of-TF-graph)
    resources: {cores: 2, memory_mb: 4096, disk_gb: 8}   # defaults; env config may override
    options:   {nesting: true, unprivileged: true}
config:
  required: [node, ip, ct_id]  # validated generically; DISABLED components need nothing
  optional: [network]
consumes:                      # capability-keyed — see §5
  resolvers: {capability: dns.resolver, many: true, optional: true}
provides:
  - {capability: dns.record, value: "<name> A {ip}"}
ansible:
  playbook: playbook.yml
  groups: [<inventory groups this component's hosts join>]   # inventory only, not deps
env: [<ENV_VARS this component contributes to .envrc/.env.mk>]
seam:                          # declared manual/extension write surfaces — see §6
  - {file: <daemon include-dir or fragment dir>, kind: include-dir}
bootstrap: <script>            # only for kind: none (e.g. the state backend)
placeholder: CHANGE_ME         # declared sentinel contract (core default, overridable)
```

`kind: none` + `bootstrap:` expresses "Ansible-only, provisioned out-of-band" as a declared
property — the state backend stops being an if-ladder special case.

## 5. Capability model (values: consumer pulls, always)

Dependencies are keyed by **capability contracts, never component names** — a consumer
cannot know whether its provider is public or private, one or many:

- **Hard consume**: provider absent/disabled while consumer enabled ⇒ validation error at
  `make configure`.
- **Optional consume** (`optional: true`): provider enabled → value injected into the
  consumer's group vars; provider absent → the var **does not exist** and the role gates on
  it (`when: x is defined`). No dummy values, no dead config.
- **Cardinality** (`many: true`): resolution aggregates *all* enabled providers (public and
  overlay alike) into a list. Two providers of a single-valued capability ⇒ validation
  error; `priority` breaks deliberate ties.
- **Reverse direction is load-bearing**: a public component may be the consumer aggregating
  private providers — e.g. the DNS component consumes `dns.record` (many) and templates its
  zone from whatever arrives; every component (public or private) provides its own record.
  This replaces the hand-maintained records playbook.
- **Re-convergence is computed**: when the provider set of a capability changes, every
  consumer of that capability is stale; the generator reports the re-run list. "A new
  service impacts all other hosts" becomes a printed to-do, not tribal memory.

Initial capability set expected from migrating the six public components:
`dns.resolver`, `dns.record`, `ca.url`, `ca.trust`, `syslog.target`, `apt.source`,
`s3.endpoint`. Named during migration, not designed up front.

## 6. Behavioral extension (logic: provider push, bounded by seams)

When an extension is *behavior* on hosts the extending component does not own (join every
host to a directory, add a rule to another daemon), the extending component ships **its own
play targeting existing inventory groups** (`hosts: all` is legitimate). Three rules bound
it:

1. **Disjoint ownership needs no seam** — new files/daemons no public component manages
   (e.g. a new agent's own config) are wholly owned by the extending component.
2. **Touching public-owned surface requires a declared seam** — daemon-native include
   mechanisms preferred (sshd `Include *.conf` dirs, nginx `conf.d/`, dnsdist
   `includeDirectory()`, systemd drop-ins, `sudoers.d/`, app plugin/app dirs, admin APIs);
   `blockinfile`/`assemble` as fallbacks where a daemon cannot include. The same seam serves
   human hand-edits and component extensions — one mechanism for both.
3. **Templating over a public component's managed base file is never allowed** — two owners
   of one file is the clobber problem reborn.

If a private need hits an undeclared surface, the escape valve is a small **contract-shaped
public commit** (add a capability or seam, no logic). By design, this is the only case where
private extension touches the public tree.

`.envrc` gets its own seam (it is not daemon-shaped): generated `.envrc` sources a
never-templated `.envrc.local`; the smart-merge may never delete a key it did not create.

## 7. Worked stress test — a private directory service (LDAP)

| Demand | Mechanism | Public commits |
|---|---|---|
| Provision its LXC | overlay dir → services map → generic `for_each` | 0 |
| DNS record | provides `dns.record`; public DNS consumes (many) | 0 |
| TLS cert | consumes `ca.url` | 0 |
| Directory client on all hosts | own play `hosts: all`; client daemon's files are disjoint ownership | 0 |
| sshd/sudo policy tweaks | fragments into declared seams | 0 |
| App-level auth in API-configurable services | admin-API push from its own play | 0 |
| App-level auth in fragment-native services | drop-in app/fragment dir (declared seam) | 0 |
| App-level auth in monolithic-config services | gated optional consume or new seam | 1 small contract commit |
| Verify/collect | `verify.sh` in its dir, discovered | 0 |
| Secrets | `.envrc.local` + `config/<env>.local.yml` | 0 |

Known limit (accepted): a private component that wants to change *how* a public role does
something it already does is modification, not extension — that takes a public commit.
Overridable role internals are deliberately **not** built speculatively.

## 8. What this does and does not solve

- **apt/HTTPS trust chicken-and-egg** (`docs/known-issues.md`): the in-host bootstrap
  ordering (trusting the internal CA requires packages; packages come from the TLS'd
  mirror) is runtime phase logic — it stays with the phase-keyed fallback design
  (`docs/design/apt-fallback-policy.md`), unchanged. What this architecture adds is the
  **coordination half**: when the CA/mirror provider appears or changes, the capability
  graph names every stale consumer and the re-converge list is computed instead of
  discovered by failure.

## 9. Co-refactored observations (agreed in scope)

1. **Primitive module interfaces normalized** — vm/lxc modules currently diverge on ~17
   variable names for the same concepts; same names both sides, kind-specific extras
   optional with defaults. Precondition for the `for_each` collapse.
2. **`outputs.tf`** collapses to a map keyed by instance.
3. **Makefile/verify-all/collect-all** switch to pattern rules over the discovered
   component set — no hand lists, no per-service special cases.
4. **`config/*.example.yml` assembled from component fragments** — otherwise examples go
   stale or leak private shapes.
5. **State migration**: the collapse renames every address (`module.x[0]` →
   `module.lxc["x"]`) — handled with `moved {}` blocks, verified by expected-empty plan.
   Production migration is operator-applied via handoff, as ever.
6. **Agent-host facts** (SSH key path, ssh args, proxy or none) move into config → the
   generated `ansible.cfg`; committed files stop encoding *where the agent runs*.
7. **Devcontainer retired**: its emitter (`allowed_cidrs`), proxy conventions, and related
   rules/aliases are removed; agent environments are config profiles. Half-alive is the one
   wrong answer.
8. **Hook path updates ride the same commits** — the protected-path guard must track the
   restructure or it silently stops guarding (or blocks the refactor).
9. **Per-component docs co-locate** with the component; `docs/design/` keeps cross-cutting
   records only.
10. **Placeholder sentinel** becomes a declared, validated contract (manifest field with a
    core default).

## 10. Execution plan

Big-bang on one branch, behind the golden oracle. Where output legitimately changes, the
golden regen is deliberate and **is** the review surface; everywhere else goldens stay
byte-identical.

| Phase | Work | Gate |
|---|---|---|
| **0** | `.envrc.local` seam; fix `test-generator.py` (red on main); placeholder validation | unit layer green before goldens legitimately move |
| **1** | normalize module interfaces; `for_each` collapse; `services` map (typed object, `optional()` fields); outputs map; `moved{}` | one deliberate golden regen (tfvars) |
| **2** | discovery engine; migrate the six public components into `components/`; generic emitters; Makefile pattern rules; capability set named; examples assembled | byte-identical goldens except deliberate diffs |
| **3** | `components.local/` + `config/<env>.local.yml`; collision = error; dummy private component as the test | overlay proven with a synthetic component |
| **4** | capability resolution (hard/optional/many) + re-converge reporting; per-component seams | inventory golden diffs reviewed |
| **5** | *(separate branch)* `.claude/` harness rewrite (harvest `rules/` first — do not blank-delete); docs restructure; devcontainer removal cleanup | after structure lands |

Decisions intentionally left to implementation: exact manifest field names (forced by the
six migrations, reviewed as one diff); `resources` defaults in manifest with per-env config
override (sandbox/prod sizing legitimately differs).
