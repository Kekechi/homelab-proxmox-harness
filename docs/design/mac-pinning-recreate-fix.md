# Deferred task: pin guest MAC addresses to eliminate same-IP-reuse reachability gap

**Status:** deferred — design agreed, not yet implemented.
**Stakes:** loop reliability (sandbox rebuild). Not a production blocker.

## Problem (root cause confirmed)

When a guest is destroyed and recreated at the **same IP** but with a **new
link-layer (MAC) address**, the upstream L3 gateway keeps its cached IP→MAC
mapping pointing at the now-dead MAC until that cache entry ages out (on the
order of ~15–20 min). During that window, inbound traffic to the guest is
blackholed even though the guest is up and healthy.

This bites the destroy→rebuild loop specifically, because every recreate gets a
fresh random MAC from the hypervisor, and the loop recreates guests rapidly
while the gateway's cache entry is still "hot" (recently refreshed → full TTL
ahead of it). A single rebuild from idle usually escapes it because the entry
has already expired; back-to-back loop iterations do not.

Confirmed this session by direct observation on the gateway (cache entry,
timed recovery correlation, and a controlled MAC-swap test). The
deployment-specific evidence (timestamps, addresses, gateway product) is
recorded in operator memory, not here (public repo).

## Why this is the fix, and why the alternatives were rejected

The root cause is the **MAC changing on recreate**. Pin the MAC and the gateway's
cached entry never goes stale — no blackhole, no announcement needed.

- **Gratuitous-ARP at boot (`arp_notify=1`)** — *verified to work* (the gateway
  accepts the unsolicited announcement and updates immediately), but it has to be
  active *before* the first interface-up, which means baking it into the OS
  template. We use **stock downloadable templates**, so this would require
  building and maintaining a custom template for one sysctl. Not worth it.
  An Ansible-applied sysctl can't help: the blackhole happens on first boot,
  before Ansible can reach the host, and a later reboot keeps the same MAC.
- **Host-side hook (hypervisor `hookscript` firing a gratuitous ARP)** — works in
  principle but is operator-host-owned, needs `arping` in the guest, has start
  timing caveats, and likely can't be expressed via the IaC provider. Clunky.
- **MAC pin** — lives entirely in IaC we own, no template, no host config, no
  first-boot timing problem. This is the right layer.

MinIO (recreated outside Terraform by `scripts/loop/recreate-minio.sh`) is
**already pinned** via an optional `services.minio.mac` field. This task
generalizes the same idea to the Terraform-managed guests.

## Scope of change

Optional, opt-in `mac:` field per service in `config/<env>.yml`. Absent → current
behavior (hypervisor assigns a random MAC). Present → pinned.

1. **LXC module** (`terraform/modules/proxmox-lxc/`)
   - `variables.tf`: add `mac_address` (string, default `null`).
   - `main.tf`: set `mac_address` on the `network_interface` block (line ~88).
   - **Verify first:** confirm `proxmox_virtual_environment_container`'s
     `network_interface` accepts `mac_address` against the bpg/proxmox provider
     docs before relying on it. (Per repo convention: verify provider behavior,
     don't assert it.)
2. **VM module** (`terraform/modules/proxmox-vm/`) — only if pinning VMs too
   (root-ca, splunk):
   - `variables.tf`: add `mac_address` (default `null`).
   - `main.tf`: set `mac_address` on the `network_device` block (line ~37).
   - Verify `network_device` accepts `mac_address` the same way.
3. **Root variables** (`terraform/variables.tf`): add `<service>_mac` per pinnable
   service (default `null`).
4. **Generator** (`scripts/genconfig/emit/tfvars.py`): emit `<service>_mac` from
   each service's optional `mac:` field.
5. **main.tf module calls**: pass `mac_address = var.<service>_mac` through.
6. **Example configs** (`config/sandbox.yml.example`, `config/production.yml.example`):
   document the optional `mac:` field with a one-line comment per service.

## Open decisions for the implementing session

- **Explicit vs derived MACs.** Either (a) operator sets an explicit `mac:` per
  service (simple, matches the MinIO precedent, but hand-maintained), or (b) the
  generator *derives* a stable MAC deterministically (e.g. from the service IP or
  vmid) so there's nothing to maintain. The agreed direction is the **optional
  explicit field**; derivation is a possible enhancement, not required.
  If deriving, use a locally-administered, unicast OUI (second-least-significant
  bit of the first octet set, multicast bit clear) to avoid collisions.
- **Which guests to pin.** At minimum the ones the loop recreates hot. Pinning all
  is cheapest to reason about (root cause gone everywhere) and is the
  recommendation; scoping to a subset is an option if any guest must keep a
  hypervisor-assigned MAC for an external reason.
- **Interaction with MinIO's existing pin.** Keep `services.minio.mac` as-is
  (read by `recreate-minio.sh`, outside Terraform). This task does not move MinIO
  under Terraform; it adds the parallel mechanism for the TF-managed guests.

## Verification (when implemented)

Reproduce the hot-entry case: prime the gateway's cache for a guest's IP, then
recreate that guest via the loop with `mac:` pinned, and confirm it is reachable
within seconds (not after a multi-minute age-out). Contrast with an unpinned
guest in the same run to show the difference. A green `--include-vms` loop with
all guests pinned is the acceptance bar.
