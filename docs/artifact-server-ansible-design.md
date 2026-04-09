# Design: Ansible — Nexus Repository CE (`nexus` LXC)

## Goal

Deploy Sonatype Nexus Repository CE on the `nexus` LXC (CT 205 sandbox / 105 production).
Nexus serves as the single artifact server for the homelab: APT packages, OCI/container
images, and Terraform providers. nginx terminates TLS on the same LXC; step-ca issues the
cert. MGMT hosts pull packages from Nexus instead of the internet; the artifact server is
the only MGMT host (alongside Proxmox) with controlled internet egress.

## Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Installation method | Tarball to `/opt/sonatype/nexus-<version>` | No APT repo exists; tarball is the only supported non-container Linux path (official docs) |
| JVM | Bundled JRE (since v3.78) | No system Java needed; tarball includes recommended JVM |
| Install path | `/opt/sonatype/nexus-<version>` symlinked to `/opt/sonatype/nexus` | Official convention (run-as-a-service docs); symlink enables clean version upgrades |
| Version pinning | `nexus_version` + `nexus_checksum` in `defaults/main.yml` | Reproducible across rebuilds; consistent with MinIO role pattern |
| Data directory | `/mnt/nexus-data/work/` via `-Dkaraf.data` in `nexus.vmoptions` | Official mechanism; data on separate disk per infrastructure design |
| Blob store | `/mnt/nexus-data/blobs/default/` (sibling of `work/`, absolute path) | Official recommendation: blobs outside `$data-dir`; single-disk convention; independently snapshotable |
| Service user | `nexus` system user, shell `/usr/sbin/nologin`, home `/opt/sonatype` | Least-privilege; `nexus.rc` sets `run_as_user="nexus"` (required since v3.80) |
| Systemd unit | Official template: `Type=forking`, `LimitNOFILE=65536`, `TimeoutSec=600` | Taken verbatim from official run-as-a-service docs |
| TLS termination | nginx reverse proxy on same LXC (8443 → localhost:8081) | Official recommendation; simpler PEM cert management vs Java keystore |
| Docker registry port | nginx 5000 (TLS) → localhost:5001 (Nexus group connector, plain HTTP) | Single external port; group repo with `writableMember` handles both push and pull |
| Docker repos | hosted + proxy (Docker Hub) + group (port 5001 internal, `writableMember: docker-hosted`) | Group aggregates both; clients use one URL for push and pull |
| APT proxy repos | Three: `trixie`, `trixie-security`, `trixie-updates` | Full Debian update coverage; security updates must not fail silently on MGMT hosts |
| Terraform registry | Proxy repo → `registry.terraform.io` | Caches providers for dev container; no GPG key needed (hosted deferred — requires writing custom providers in Go) |
| Onboarding wizard | Disabled via `nexus.properties` before first start | Prevents wizard interference with bootstrap API calls |
| Anonymous access | Disabled via API during bootstrap | MGMT segment; no reason for unauthenticated reads |
| TLS cert lifecycle | `cert-renewer@.service` (`Type=oneshot`) + `cert-renewer@.timer` systemd template, instantiated as `cert-renewer@nginx` | Smallstep-recommended timer pattern; more operationally visible than `--daemon` service; reusable across future services; extract to shared role when second user arrives. Note: does NOT use `step ca renew --daemon`; the timer drives scheduling, service runs once and exits |
| cert-renewer service user | `root` | Needs to write cert files (owned by `www-data`) and run `systemctl try-reload-or-restart nginx`; root bypasses file permission checks without altering ownership |
| Cert renewal auth | Existing cert (no provisioner password) | step-ca renewal authenticates using the existing cert; provisioner password only needed for initial issuance in `tls.yml` |
| nginx user | `www-data` (Debian default) | Standard; cert files owned by `www-data:www-data` |
| OS | Debian 13 Trixie | Current stable (released 2025-08-09); Nexus bundles JRE so no OS-level Java dependency |
| Role structure | Single `nexus` role, orchestrated `main.yml` + focused task includes | Consistent with `pdns_auth_recursor` pattern |

## Component Summary

| Component | Type | Network (prod) | Network (sandbox) | Always-on |
|---|---|---|---|---|
| Nexus CE + nginx | LXC | MGMT | Sandbox VLAN | Yes |

## Directory Layout

```
/opt/sonatype/
  nexus-<version>/          # application binaries + bundled JRE (nexus:nexus 0755)
  nexus -> nexus-<version>  # symlink — updated on version upgrade

/mnt/nexus-data/            # second disk, formatted ext4, mounted via fstab (nexus:nexus 0750, no noexec)
  work/                     # $data-dir (karaf.data) — nexus:nexus 0750
    etc/                    # created by configure.yml before first start — nexus:nexus 0750
      nexus.properties      # app config overrides (onboarding.enabled=false)
    db/                     # created by Nexus on first start
    log/
    tmp/
  blobs/
    default/                # default blob store (created by configure.yml — nexus:nexus 0750)

/etc/nginx/
  certs/
    nexus.crt               # step-ca cert (www-data:www-data 0640)
    nexus.key               # (www-data:www-data 0600)
  conf.d/
    nexus.conf              # vhost: 8443 + 5000
```

## JVM Configuration (`$install-dir/bin/nexus.vmoptions`)

```
-Xms2703m
-Xmx2703m
-XX:MaxDirectMemorySize=2g
-Dkaraf.data=/mnt/nexus-data/work
-Djava.io.tmpdir=/mnt/nexus-data/work/tmp
```

Note: data disk must not use `noexec` (tmpdir requires exec).

## nginx Ports

| External port | Protocol | Upstream | Purpose |
|---|---|---|---|
| 8443 | HTTPS (TLS) | `http://127.0.0.1:8081/` | Nexus UI + APT + Terraform repos |
| 5000 | HTTPS (TLS) | `http://127.0.0.1:5001/` | Docker registry (group connector) |

Both server blocks share the same step-ca cert (`nexus.<domain>`).

Key nginx directives: `proxy_buffering off`, `proxy_request_buffering off`,
`client_max_body_size 1G`, `proxy_read_timeout 300`, `X-Forwarded-Proto "https"`,
`proxy_set_header Host $host:$server_port` (Docker block only — Docker clients include port).
Standard block uses `proxy_set_header Host $host`.

## Repository Summary (Day 1)

| Name | Type | Remote URL | Distribution / Index | Connector port |
|---|---|---|---|---|
| `apt-proxy-trixie` | APT proxy | `http://deb.debian.org/debian` | `trixie` | — |
| `apt-proxy-trixie-security` | APT proxy | `http://security.debian.org/debian-security` | `trixie-security` | — |
| `apt-proxy-trixie-updates` | APT proxy | `http://deb.debian.org/debian` | `trixie-updates` | — |
| `docker-hosted` | Docker hosted | — | — | none (push routed via group `writableMember`) |
| `docker-proxy` | Docker proxy | `https://registry-1.docker.io` | `HUB` index | — |
| `docker-group` | Docker group | hosted + proxy, `writableMember: docker-hosted` | — | 5001 (internal) |
| `terraform-proxy` | Terraform proxy | `https://registry.terraform.io` | — | — |

## Bootstrap Sequence

1. Wait for `GET /service/rest/v1/status/writable` (loop, timeout ≥ 180s)
2. `stat $data-dir/admin.password`
   - Present → `slurp` and use as current credential for step 3
   - Absent → use `NEXUS_ADMIN_PASSWORD` as current credential; if step 3 returns 401, `fail` explicitly (do not silently skip — operator must correct the password)
3. `PUT /service/rest/v1/security/users/admin/change-password` (Content-Type: text/plain body)
4. `PUT /service/rest/v1/security/anonymous` `{"enabled": false}`
5. `POST /service/rest/v1/blobstores/file` → `{"name": "default", "path": "/mnt/nexus-data/blobs/default"}`
6. Create repos (check existence before POST; treat 400/409 as already-exists — idempotent):
   - APT proxy × 3: each with `apt.distribution` matching the table above
   - Docker hosted: no `httpPort`
   - Docker proxy: `dockerProxy.indexType: "HUB"`, `docker.v1Enabled: true`
   - Docker group: `docker.httpPort: 5001`, `group.writableMember: "docker-hosted"`
   - Terraform proxy: `proxy.remoteUrl: "https://registry.terraform.io"`
7. All `uri` tasks run on the Nexus LXC (loopback `127.0.0.1:8081`), not the controller; `no_log: true` on all tasks touching credentials

## Role Structure

```
ansible/roles/nexus/
  defaults/main.yml          # see key variables below
  meta/main.yml              # dependencies: [] (explicit, per repo pattern)
  tasks/
    main.yml                 # orchestration — include_tasks in order
    install.yml              # disk format+mount, tarball download+verify, extract, symlink, nexus user, dir ownership
    configure.yml            # nexus.vmoptions, nexus.rc, $data-dir/etc/ creation, nexus.properties, systemd unit
    nginx.yml                # nginx install (APT), vhost template, cert dirs
    tls.yml                  # step ca certificate issuance + cert-renewer timer deployment
    bootstrap.yml            # wait-ready → password → anonymous → blob store → repos
    verify.yml               # /status/writable, docker /v2/, repo list assertions
  templates/
    nexus.vmoptions.j2
    nexus.rc.j2              # run_as_user="{{ nexus_user }}"
    nexus.service.j2
    nexus.conf.j2            # both server blocks (8443 + 5000)
    cert-renewer@.service.j2
    cert-renewer@.timer.j2
  handlers/
    main.yml                 # Restart nexus, Reload nginx, Reload systemd
```

**Role dependency:** `step_client` must run before `nexus` (provides `step` binary for cert issuance
and renewal). Enforced via playbook ordering; `meta/main.yml` has `dependencies: []`.

## Key Defaults Variables

| Variable | Example value | Purpose |
|---|---|---|
| `nexus_version` | `"3.89.0-01"` | Pinned tarball version |
| `nexus_checksum` | `"sha256:abc123..."` | Tarball integrity; from Sonatype download page |
| `nexus_download_url` | `"https://download.sonatype.com/nexus/3/nexus-{{ nexus_version }}-unix.tar.gz"` | Constructed from version |
| `nexus_install_dir` | `"/opt/sonatype"` | Parent for versioned dir + symlink |
| `nexus_user` | `"nexus"` | OS service user |
| `nexus_data_dir` | `"/mnt/nexus-data/work"` | `karaf.data` value |
| `nexus_blobs_dir` | `"/mnt/nexus-data/blobs"` | Blob store root |
| `nexus_data_mount` | `"/mnt/nexus-data"` | Second disk mount point |
| `nexus_http_port` | `8081` | Nexus plain HTTP (loopback) |
| `nexus_https_port` | `8443` | nginx external TLS |
| `nexus_docker_external_port` | `5000` | nginx Docker external TLS |
| `nexus_docker_connector_port` | `5001` | Nexus Docker group internal connector |
| `nexus_data_device` | `"/dev/sdb"` | Block device for second disk; verify with `lsblk` after Terraform apply |
| `nexus_domain` | *(omit from defaults — must be set explicitly)* | FQDN for TLS cert and nginx server_name; assert at top of `main.yml` (`nexus_domain is defined and nexus_domain \| length > 0`) |

## Changes Required Outside the Role

**`scripts/generate-configs.py`:**
- `NEXUS_ADMIN_PASSWORD` already planned in `gen_envrc()` and `_ENVRC_SECRET_VARS` (per infrastructure design)

**`ansible/playbooks/nexus-setup.yml`:** new playbook targeting `nexus` group, applying `step_client`
then `nexus` roles.

## Implementation Notes (for code generator)

- **Task ordering:** install (disk+mount → tarball → user → dirs) → configure (vmoptions + nexus.rc + `$data-dir/etc/` + nexus.properties + systemd unit) → start nexus → nginx (install + config) → tls (cert issuance + cert-renewer units) → bootstrap → verify
- **Disk format + mount in `install.yml`:** `blkid` check before `mkfs.ext4`; write `/etc/fstab` entry with `nodev,nosuid` (no `noexec`); `mount -a`; set `nexus:nexus 0750` ownership after mount
- **`$data-dir/etc/` and `blobs/default/` created in `configure.yml`:** `nexus:nexus 0750`; must exist before Nexus starts (especially `etc/nexus.properties`)
- **`nexus.vmoptions` location:** `$install-dir/bin/nexus.vmoptions` (install dir, not data dir)
- **`nexus.properties` location:** `$data-dir/etc/nexus.properties` = `/mnt/nexus-data/work/etc/nexus.properties`
- **`nexus.rc` location:** `$install-dir/bin/nexus.rc` — must be created before starting the service (required since v3.80)
- **Docker connector port:** group connector `httpPort: 5001` (internal); nginx proxies `5000 TLS → localhost:5001 HTTP`; hosted repo has no `httpPort` (push routes through group via `writableMember`)
- **`admin.password` idempotency:** `stat` → conditional `slurp`; always attempt password change; explicit `fail` on 401 when `admin.password` absent; `no_log: true` on all credential tasks
- **cert-renewer pattern:** `Type=oneshot` service (NOT `--daemon`); timer fires every 15 minutes; `ExecCondition: step certificate needs-renewal {{ cert_path }}`; `ExecStart: step ca renew --force {{ cert_path }} {{ key_path }}`; `ExecStartPost: systemctl try-reload-or-restart nginx`; service runs as `root`
- **Cert renewal — no provisioner password:** `step ca renew` authenticates using the existing cert; provisioner password is only needed in `tls.yml` for initial issuance (same pattern as MinIO `tls.yml`)
- **nginx reload, not restart:** cert renewal triggers `systemctl try-reload-or-restart nginx` — graceful, zero dropped connections
- **Tarball extract:** `tar xvzf nexus-<version>-unix.tar.gz -C /opt/sonatype` then `ansible.builtin.file` symlink task; the `--keep-directory-symlink` flag is for upgrade reruns (see Unvalidated Assumptions)
- **Nexus startup time:** 1–3 minutes on first start; `wait_for` / `uri` loop in bootstrap needs timeout ≥ 180s
- **Blob store path:** absolute path (`/mnt/nexus-data/blobs/default`) in POST body — relative paths resolve under `$data-dir/blobs/` which would put blobs inside `work/`
- **`no_log: true`** on all tasks touching `NEXUS_ADMIN_PASSWORD` or `STEP_CA_PROVISIONER_PASSWORD`

## Unvalidated Assumptions (verify on first deploy)

| Assumption | How to verify |
|---|---|
| `nexus.properties` written before first start disables onboarding wizard | Check Nexus logs for wizard init messages on first start |
| Docker push through group `writableMember` works as expected | `docker push nexus.<domain>:5000/test:latest` on first deploy |
| Terraform proxy repo discovery works for `terraform init` | Run `terraform init` against Nexus registry from dev container after deploy |
| APT proxy `distribution` field matches Trixie LXC template sources | Check `/etc/apt/sources.list.d/` on a deployed LXC |
| `tar --keep-directory-symlink` is the correct flag for upgrade-safe extraction | Verify on first upgrade; remove if symlink is created separately and flag is not needed |
| Second disk device name is `/dev/sdb` on the LXC | Check `lsblk` after Terraform apply; update `nexus_data_device` default if different |

## Open Items (deferred)

| Item | Deferred to |
|---|---|
| Consumer onboarding (APT source config per host) | After Phase 1 stable |
| Nexus Base URL capability | Post-deploy config if email notifications needed |
| Additional APT distributions (Ubuntu, etc.) | When workstations onboard |
| Generic HTTP proxy for LXC templates/ISOs | Phase 2 — pending pveam configurability check |
| Blob store quota configuration | Post-deploy tuning |
| Hosted Terraform registry | Only if custom providers are written (unlikely) |

## Ready for Planning

Design is complete. Run `/infra-plan` with `docs/artifact-server-design.md` (Terraform scope)
and this document (Ansible scope) as input.

The plan should produce:
1. `ansible/roles/nexus/` — full role per role structure above
2. `ansible/playbooks/nexus-setup.yml` — playbook targeting `nexus` group
