---
name: ansible-run
description: Pre-flight verification, playbook execution, and idempotency check for Ansible deployments against real infrastructure.
disable-model-invocation: true
---

# Skill: Ansible Run

Execute an Ansible playbook against real infrastructure with pre-flight safety checks and post-run verification.

## Phase 1: Pre-flight

### Generator check

If `scripts/generate-configs.py` was modified in this session, confirm `make configure` has been run before proceeding:

```bash
grep "CHANGE_ME" /workspace/.envrc
```

Any `CHANGE_ME` value added by the generator patch means the secret hasn't been filled in yet. A role that asserts on the env var will fail on the first task — catch it here rather than mid-run. If new secrets are present, stop and ask the operator to fill them in and run `direnv allow`.

### Connectivity check

Verify all target hosts are reachable before running:

```bash
ansible <group> -m ansible.builtin.ping
```

Stop if any host is unreachable. Do not proceed with a partial inventory.

### Syntax check

```bash
ansible-playbook <playbook> --syntax-check
```

Catches YAML errors and undefined variables before touching any host.

### CLI flag verification (first-time deployments only)

For any task that calls a CLI tool (`step-ca`, `consul`, `vault`, etc.) for the first time, verify every non-trivial flag exists in the installed binary version on the target:

```bash
ansible <host> -m ansible.builtin.command -a "<tool> <subcommand> --help" 2>&1 | grep "<flag>"
```

**If a flag is missing:** fix the task now. Do not proceed and fix after first failure.

This step is mandatory on first-ever runs of a role against a new tool version. Static code review cannot catch version-specific CLI behavior.

## Phase 2: Run

```bash
ansible-playbook <playbook>
```

- Run from the `ansible/` directory so `ansible.cfg` is picked up
- If the playbook targets multiple host groups, run against one host first with `--limit <host>` if the role is untested

On failure:
- Read the full error output — `stderr` is almost always more informative than the task summary
- If the failure is in a `no_log: true` task, re-run with `-v` to confirm which task failed, then check the task directly on the host
- Fix the root cause before re-running — do not retry identical failures

## Phase 3: Verify

### Service/application check

Confirm the deployed service is running and responding:

```bash
ansible <host> -m ansible.builtin.command -a "systemctl is-active <service>"
ansible <host> -m ansible.builtin.uri -a "url=https://<endpoint>/health validate_certs=no"
```

### Idempotency check

Re-run the playbook immediately. All tasks should report `ok`, none `changed`:

```bash
ansible-playbook <playbook>
```

If any task still reports `changed` on the second run, the role is not idempotent — investigate before declaring the deployment complete.

## Constraints

- Always run from `ansible/` directory — `ansible.cfg` sets `roles_path`, `private_key_file`, and `ssh_args`
- Never skip the connectivity check — a partial run against unreachable hosts produces hard-to-recover partial state
- Never retry a failed run without reading and understanding the error first
