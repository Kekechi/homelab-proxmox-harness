# DNS cache invalidation — why a new record keeps answering NXDOMAIN

Symptom: a record demonstrably exists in the authoritative zone
(`pdnsutil list-zone <zone>` shows it), but clients — and even `dig` against
the front-end — keep getting NXDOMAIN for up to an hour.

## Why this happens: negative caching

A *miss* is cached just like a hit (RFC 2308). When something queries a name
**before** its record exists, every cache on the path stores the NXDOMAIN,
with a TTL taken from the zone's **SOA minimum** field (this zone: 3600s = 1h).
Creating the record afterwards does not evict those entries — the chain keeps
serving the cached miss until it expires or is flushed.

This bites in exactly two situations, both observed here:

- **Deploy ordering**: a service queried its dependency's name during setup,
  seconds before the records play ran.
- **Manual record additions**: you add a record, test it, and the test itself
  (or an earlier one) had already seeded the negative entry.

## The cache layers, closest-to-authority first

| Layer | Where | Native flush | Blunt flush |
|---|---|---|---|
| 1. PowerDNS Auth packet cache | auth host | `pdns_control purge "<name>$"` | `systemctl restart pdns` |
| 2. PowerDNS Recursor cache | auth host (colocated) | `rec_control wipe-cache <name>` | `systemctl restart pdns-recursor` |
| 3. DNSdist packet cache | dist host | dnsdist console: `getPool(""):getCache():expungeByName(newDNSName("<name>"))` | `systemctl restart dnsdist` |
| 4. Client-side | each client | `resolvectl flush-caches` (systemd-resolved), browser restart | — |

Flush **in that order** (authority outward). Flushing only the front-end is not
enough: dnsdist will re-fetch the still-cached NXDOMAIN from the recursor —
this exact trap was hit live (dnsdist restart alone changed nothing; recursor
restart then dnsdist restart fixed it).

**Verification status** (per this repo's evidence discipline): the
service-restart path is verified on this deployment; the `pdns_control` /
`rec_control` / dnsdist-console commands are the vendors' documented native
flushes but have not yet been exercised here — prefer them once confirmed, as
restarts drop the entire cache.

## Quick recipe after adding/changing a record

```bash
# 1) confirm the zone actually has it (on the auth host)
pdnsutil list-zone <zone> | grep <name>

# 2) flush the chain (blunt-but-verified form)
systemctl restart pdns-recursor      # auth host
systemctl restart dnsdist            # dist host

# 3) re-query through the front-end
dig +short <name>.<zone> @<dnsdist-ip>
```

In the IaC flow, records land via the dns component's records play (the
`dns.record` capability aggregate) — run it *before* anything queries the new
name and the negative entry never gets seeded.

## Prevention knobs

- **Create before query**: deploy ordering already runs the records play right
  after the auth setup; keep new-service bring-up in that order.
- **Lower the SOA minimum** (zone design choice): shrinks the negative-cache
  window for everything, at the cost of more upstream misses. Worth considering
  if manual record work is frequent.
