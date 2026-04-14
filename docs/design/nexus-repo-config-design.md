# Design: Nexus Repository Configuration — Data-Driven Repos + Proxmox Proxy

## Goal

Replace the hardcoded per-repo task blocks in the Nexus bootstrap with a data-driven list
sourced from `config/<env>.yml`. Add proxy repos for Proxmox VE and Ceph packages so that
PVE nodes on the management segment can use Nexus as their sole APT source.

---

## Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Repo list structure | Data-driven list, one loop task | Current approach duplicates 20-line task blocks per repo. All APT proxy repos share identical structure; only `name`, `remote_url`, `distribution`, and `flat` vary. Loop replaces N hardcoded tasks. |
| Config location | `config/<env>.yml` under `services.nexus.apt_proxy_repos` | Consistent with project pattern. Config is gitignored — repo list is not committed to the public repo. Per-env control (sandbox vs production can differ). Generator passes the list through as-is; no derivation. |
| Role default | `nexus_apt_proxy_repos: []` in `defaults/main.yml` | Empty fallback so inventory always wins. Role never silently adds repos. |
| IaC-required repos | Explicit in config; generator validates required names are present | Source of truth is one place. Generator fails fast with a clear message if a required repo is missing rather than silently including hidden defaults. `.example` files annotate which repos are IaC-required. |
| New repos | `apt-proxy-proxmox-pve` + `apt-proxy-proxmox-ceph-squid` | Both confirmed from live PVE 9 node (`/etc/apt/sources.list.d/`). Enterprise repos are disabled on the node — not proxied. Base Debian already covered by existing trixie repos. |
| PVE client-side config | Manual `/etc/apt/sources.list.d/` file (DEB822 format) | Proxmox repository UI is toggle-only for predefined entries — confirmed against PVE 9.1.2 official docs. Custom repos require direct file editing. Documented in `docs/guides/non-managed-host-setup.md`. |

---

## Component Summary

### New Nexus APT proxy repos

| Repo name | Remote URL | Suite | Flat | IaC-required |
|---|---|---|---|---|
| `apt-proxy-proxmox-pve` | `http://download.proxmox.com/debian/pve` | `trixie` | false | No |
| `apt-proxy-proxmox-ceph-squid` | `http://download.proxmox.com/debian/ceph-squid` | `trixie` | false | No |

Existing repos (trixie, trixie-security, trixie-updates, smallstep, powerdns-auth-50,
powerdns-rec-54, dnsdist-21) move into `config/<env>.yml` with no changes to their values.

### Config schema

```yaml
# config/<env>.yml
services:
  nexus:
    apt_proxy_repos:
      # IaC-required — do not remove
      - name: apt-proxy-trixie
        remote_url: "http://deb.debian.org/debian"
        distribution: trixie
      - name: apt-proxy-trixie-security
        remote_url: "http://security.debian.org/debian-security"
        distribution: trixie-security
      - name: apt-proxy-trixie-updates
        remote_url: "http://deb.debian.org/debian"
        distribution: trixie-updates
      - name: apt-proxy-smallstep
        remote_url: "https://packages.smallstep.com/stable/debian"
        distribution: debs
        flat: true
      # ... other IaC-required repos ...
      # Optional — add when PVE nodes are present
      - name: apt-proxy-proxmox-pve
        remote_url: "http://download.proxmox.com/debian/pve"
        distribution: trixie
      - name: apt-proxy-proxmox-ceph-squid
        remote_url: "http://download.proxmox.com/debian/ceph-squid"
        distribution: trixie
```

Generator emits `nexus_apt_proxy_repos` as a group var for the `nexus` inventory group.

### bootstrap.yml — two loop tasks replace all per-repo blocks

`flat` must be a JSON boolean. Without `jinja2_native`, Ansible renders `"{{ expr }}"` as a
string, so `flat` cannot be set dynamically via a Jinja2 expression. Solution: two tasks with
YAML literal bools, split by a `sameas` filter. `rejectattr('flat', 'sameas', true)` correctly
passes through repos with `flat` absent, `false`, or `null`.

```yaml
- name: Create APT proxy repos (flat: false)
  ansible.builtin.include_tasks: _create_repo.yml
  vars:
    repo_name: "{{ item.name }}"
    repo_type: apt/proxy
    repo_body:
      name: "{{ item.name }}"
      online: true
      storage:
        blobStoreName: default
        strictContentTypeValidation: true
      proxy:
        remoteUrl: "{{ item.remote_url }}"
        contentMaxAge: 1440
        metadataMaxAge: 1440
      negativeCache:
        enabled: true
        timeToLive: 1440
      httpClient:
        blocked: false
        autoBlock: true
      apt:
        distribution: "{{ item.distribution }}"
        flat: false
  loop: "{{ nexus_apt_proxy_repos | rejectattr('flat', 'sameas', true) | list }}"
  loop_control:
    label: "{{ item.name }}"

- name: Create APT proxy repos (flat: true)
  ansible.builtin.include_tasks: _create_repo.yml
  vars:
    repo_name: "{{ item.name }}"
    repo_type: apt/proxy
    repo_body:
      name: "{{ item.name }}"
      online: true
      storage:
        blobStoreName: default
        strictContentTypeValidation: true
      proxy:
        remoteUrl: "{{ item.remote_url }}"
        contentMaxAge: 1440
        metadataMaxAge: 1440
      negativeCache:
        enabled: true
        timeToLive: 1440
      httpClient:
        blocked: false
        autoBlock: true
      apt:
        distribution: "{{ item.distribution }}"
        flat: true
  loop: "{{ nexus_apt_proxy_repos | selectattr('flat', 'sameas', true) | list }}"
  loop_control:
    label: "{{ item.name }}"
```

---

## Implementation Notes

**Generator:** Add `apt_proxy_repos` pass-through under `services.nexus` in
`generate-configs.py`. Assert that the IaC-required repo names are present before emitting.
Emit as `nexus_apt_proxy_repos` in the `nexus` group vars block.

**Client-side (PVE):** PVE's native sources combine `trixie` and `trixie-updates` in a
single DEB822 entry (`Suites: trixie trixie-updates`). When pointing at Nexus, two separate
`URIs:` entries are needed since they map to separate proxy repos. Document this in
`docs/guides/non-managed-host-setup.md`.

**GPG keyring:** The Proxmox keyring (`proxmox-archive-keyring.gpg`) is already present
on running PVE nodes. Not a Nexus concern. Fresh installs would need the keyring separately
— out of scope for this design.

---

## Open Items (deferred, not forgotten)

| Item | Deferred until |
|---|---|
| `non-managed-host-setup.md` — Nexus APT config section for PVE | After this plan is implemented |
| Additional distros (Ubuntu, etc.) | When workstations onboard |
| Proxmox enterprise repo proxy | If subscription is obtained |

---

## Ready for planning

Design is complete. Hand to `/infra-plan` with:
- Refactor `bootstrap.yml`: replace per-repo task blocks with `nexus_apt_proxy_repos` loop
- Update `defaults/main.yml`: add `nexus_apt_proxy_repos: []`
- Update `generate-configs.py`: pass through `apt_proxy_repos`, assert IaC-required names
- Update `config/sandbox.yml.example` and `config/production.yml.example`: full repo list with IaC-required annotations
- Add Proxmox repos to the list in both example files
