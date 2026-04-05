# PKI Prototype Learnings — Redesign Reference

This document captures everything discovered during the first step-ca prototype.
Use it as the authoritative context document when starting the redesign session.

---

## What We Built (Prototype)

Two-tier internal PKI:
- **Root CA**: Proxmox VM (offline, powered down after init)
- **Issuing CA**: Proxmox LXC (always-on, serves ACME + admin API)
- **step-ca v0.30.2** (Smallstep OSS)
- **Ansible** roles: `step_ca_common`, `step_ca_root`, `step_ca_issuing`

The prototype works but was over-engineered and discovered five false assumptions only
at runtime through repeated review-fix-deploy cycles.

---

## What Went Wrong and Why

### Root Cause: No Design Phase

We skipped `/design` and went straight to `/infra-plan` → `/generate` → deploy.
Each review round (3+) found assumptions that should have been validated before
writing a single line of Ansible. The fix-review loop was a symptom of this gap.

### The Five False Assumptions

| # | Assumption | Reality |
|---|-----------|---------|
| 1 | `step ca init` is interactive-only | Fully headless with the right flags — one command replaces ~150 lines of Ansible |
| 2 | `step crypto jwk create` output is compatible with ca.json `encryptedKey` | It outputs JWE JSON Serialization; ca.json requires JWE Compact Serialization (5 dot-joined parts) |
| 3 | `authority.admins[].subject` controls the bootstrap admin subject | step-ca v0.30.2 hardcodes `"step"` as the first super admin subject regardless of config |
| 4 | `AmbientCapabilities=CAP_NET_BIND_SERVICE` works in Proxmox LXC | Fails silently — Proxmox seccomp filter (filter 1) blocks it |
| 5 | ACME EAB key creation is available in OSS | `step ca acme eab add` is gated to Smallstep Certificate Manager in v0.30.2 |

---

## step-ca v0.30.2 Behavioral Facts

These are **verified against the live issuing CA**, not inferred.

### `step ca init` — Non-Interactive Mode

```bash
step ca init \
  --name "Homelab Issuing CA" \
  --dns ca.sandbox.example.com \
  --address :9000 \
  --provisioner acme \
  --admin-subject step \
  --password-file /path/to/ca-password \
  --provisioner-password-file /path/to/provisioner-password \
  --deployment-type standalone \
  --acme \
  --no-db
```

For an intermediate CA (not self-signed root), add:
```bash
  --root /path/to/root_ca.crt \
  --key /path/to/intermediate_ca_key \
  --key-password-file /path/to/key-password
```

This generates a complete, valid `ca.json` and key material without any interactive prompts.
One command replaces the entire Jinja2 `ca.json.j2` template and JWK generation tasks.

### BadgerDB and `enableAdmin: true`

- When `enableAdmin: true` is set, step-ca **migrates provisioners from `ca.json` into BadgerDB on first start**.
- After migration, **step-ca reads provisioners from BadgerDB, not ca.json**. Changes to `ca.json` provisioners have no effect without a DB wipe.
- The BadgerDB `LOCK` file must be owned by the step-ca service user. If it's owned by root (from a manual diagnostic run), step-ca will fail to start with a lock error.
- To reset: `rm -f /etc/step-ca/db/LOCK && chown -R step:step /etc/step-ca/db`

### Admin Bootstrap Subject

- step-ca v0.30.2 bootstraps the **first super admin with subject `"step"`** regardless of what `authority.admins[].subject` is configured.
- All admin API calls must use `--admin-subject step`.
- Verified by reading BadgerDB vlog directly: the stored entry has `"subject":"step"`.
- Variable `step_ca_admin_subject` must be `"step"` in all group_vars.

### JWE Format for `encryptedKey`

- `step crypto jwk create` outputs **JWE JSON Serialization**:
  ```json
  {
    "protected": "...",
    "encrypted_key": "...",
    "iv": "...",
    "ciphertext": "...",
    "tag": "..."
  }
  ```
- `ca.json` `encryptedKey` requires **JWE Compact Serialization**:
  ```
  <protected>.<encrypted_key>.<iv>.<ciphertext>.<tag>
  ```
  (five base64url parts joined by `.`)
- **Converting between formats requires a script** — there is no `step` CLI flag to output compact form directly from `step crypto jwk create`.
- With `step ca init`, this problem disappears entirely — it generates the correct format automatically.

### EAB (External Account Binding)

- `step ca acme eab add` returns: *"this functionality is currently only available in Certificate Manager"*
- This is **server-side gating**, not a CLI limitation. It is enforced in v0.30.2 OSS.
- **Do not design EAB into the architecture** unless migrating to Smallstep Certificate Manager or using an OSS build ≤ v0.26.x.
- The ACME provisioner works fine for standard certificate issuance without EAB.
- `requireEAB: true` must NOT be set in the ACME provisioner config.

### Port Binding in Proxmox LXC

- **`AmbientCapabilities=CAP_NET_BIND_SERVICE` in systemd unit: FAILS**
  - Proxmox applies seccomp filter 1 to LXC containers.
  - The `capset` syscall is filtered, so ambient capabilities cannot be set.
  - The unit starts but the capability is silently dropped; binding to port 443 fails.
- **`setcap cap_net_bind_service=ep /usr/bin/step-ca`: WORKS**
  - Sets the capability on the binary itself (file capabilities).
  - The `step` user (non-root) can then bind to port 443.
  - This survives package upgrades only if the Ansible role re-runs `setcap` after install.
  - Must be run as root: `setcap cap_net_bind_service=ep /usr/bin/step-ca`
- **nginx TCP stream proxy**: Used in the prototype to avoid port binding. **Unnecessary complexity**. Eliminates with `setcap`.

---

## The Correct Approach (Redesign Blueprint)

### Architecture (unchanged)

```
Root CA VM (offline)          Issuing CA LXC (always-on)
  step-ca root cert              step-ca intermediate cert
  powered off after init         serves :443 via setcap
  powered on only to sign CSRs
```

### Bootstrap Method: `step ca init`

Replace the entire Jinja2 ca.json template and JWK generation with `step ca init`.

**Root CA init** (run once, on the root CA VM):
```bash
step ca init \
  --name "{{ pki_root_ca_name }}" \
  --dns "{{ inventory_hostname }}" \
  --address :9000 \
  --provisioner root-jwk \
  --admin-subject step \
  --password-file /tmp/root-ca.pw \
  --provisioner-password-file /tmp/root-prov.pw \
  --deployment-type standalone
```

Extract root cert, generate intermediate CSR separately using `step certificate create --csr`.

**Issuing CA init** (run once, on the issuing CA LXC, after root cert and signed intermediate cert are available):
```bash
step ca init \
  --name "{{ pki_issuing_ca_name }}" \
  --dns "{{ pki_issuing_ca_hostname }}" \
  --address :443 \
  --provisioner "{{ step_ca_acme_provisioner_name }}" \
  --admin-subject step \
  --password-file /tmp/issuing-ca.pw \
  --provisioner-password-file /tmp/issuing-prov.pw \
  --deployment-type standalone \
  --acme \
  --root /etc/step-ca/certs/root_ca.crt \
  --key /etc/step-ca/secrets/intermediate_ca_key \
  --key-password-file /tmp/issuing-ca.pw
```

### Port Binding

```yaml
- name: Grant step-ca capability to bind privileged ports
  community.general.capabilities:
    path: /usr/bin/step-ca
    capability: cap_net_bind_service=ep
    state: present
```

Or as a raw command (if `community.general` not available):
```yaml
- name: Grant step-ca capability to bind privileged ports
  ansible.builtin.command:
    cmd: setcap cap_net_bind_service=ep /usr/bin/step-ca
  changed_when: true
```

Must re-run after any package upgrade that replaces the binary.

### No nginx Stream Proxy

Remove entirely. nginx was only needed because port binding was assumed impossible.
With `setcap`, step-ca binds `:443` directly.

### Idempotency Gate for `step ca init`

`step ca init` is not idempotent — it will refuse to run if config already exists.
Gate with a `stat` check on the generated `ca.json`:

```yaml
- name: Check if step-ca is already initialized
  ansible.builtin.stat:
    path: "{{ step_ca_common_home }}/config/ca.json"
  register: step_ca_init_stat

- name: Initialize step-ca
  when: not step_ca_init_stat.stat.exists
  block:
    # tempfile + block/always for passwords
    # step ca init command
```

### Password Handling Pattern (keep from prototype)

All password file operations must use `tempfile` + `block/always`:

```yaml
- name: Create temp file for CA password
  ansible.builtin.tempfile:
    state: file
    suffix: .pw
  register: step_ca_pw_tmpfile

# ... use in command ...

always:
  - name: Remove CA password temp file
    ansible.builtin.file:
      path: "{{ step_ca_pw_tmpfile.path }}"
      state: absent
    when: step_ca_pw_tmpfile.path is defined
```

### Two-Pass Workflow (keep, but simplify)

The two-pass structure is correct for an offline root CA:

1. **Pass 1**: Root CA init → generate root cert and key. Issuing CA → generate intermediate CSR.
2. **Root CA online**: Sign the CSR, fetch signed cert to controller, power off root CA.
3. **Pass 2**: Issuing CA → `step ca init` with signed intermediate cert.

With `step ca init`, Pass 2 is a single command rather than multiple templating tasks.

---

## Lessons for the Design Session

Before writing any Ansible in the redesign, validate these at the design phase:

1. **Run `step ca init --help`** to confirm all flag names for the target version.
2. **Check `step ca init` idempotency behavior** — what error does it return if already initialized?
3. **Confirm `setcap` survives the package version** being deployed (apt install preserves file capabilities? No — setcap must be re-run after upgrade).
4. **Decide admin provisioner strategy**: with `step ca init --acme`, an ACME provisioner is created. The JWK admin provisioner is created automatically. Confirm the default name and subject created by init before designing around them.
5. **Test `step ca init` for intermediate CA** — the `--root` / `--key` / `--key-password-file` flags for initializing with an existing key. Verify it generates a correct `ca.json` for a non-self-signed intermediate.

---

## Files to Keep, Modify, or Delete in Redesign

| File | Action | Notes |
|------|--------|-------|
| `ansible/roles/step_ca_common/` | Keep | User/group/dir creation and APT install are correct |
| `ansible/roles/step_ca_root/tasks/main.yml` | Rewrite | Replace cert generation tasks with `step ca init` |
| `ansible/roles/step_ca_issuing/tasks/main.yml` | Rewrite | Replace ca.json template + JWK tasks with `step ca init`; add `setcap` |
| `ansible/roles/step_ca_issuing/templates/ca.json.j2` | Delete | Generated by `step ca init` |
| `ansible/roles/step_ca_issuing/templates/nginx-stream.conf.j2` | Delete | nginx proxy no longer needed |
| `ansible/roles/step_ca_issuing/handlers/main.yml` | Keep with guard | Handler `when` guard on signed cert stat |
| `ansible/tasks/generate_eab_key.yml` | Keep with OSS notice | EAB gated in OSS — task kept for future use, not called by default |
| `ansible/inventory/group_vars/all/step_ca.yml` | Keep | Most vars still apply; `step_ca_admin_subject: step` is correct |
| `ansible/playbooks/pki-setup.yml` | Keep structure | Play order unchanged; update comments |
| `docs/pki-setup.md` | Rewrite | Reflect new bootstrap approach |

---

## Starting the Redesign

In the next session, start with:

```
/design Complete redesign of two-tier internal PKI using step-ca.
Read docs/pki-redesign-learnings.md for full context — the prototype failures,
step-ca v0.30.2 behavioral quirks, and the correct approaches already verified.
Key decisions to confirm: step ca init flag set for intermediate CA, setcap
idempotency after package upgrades, two-pass workflow structure. Do not plan
or implement until the design is confirmed.
```
