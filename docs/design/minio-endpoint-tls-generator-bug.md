# Bug: Generator Emits IP for MINIO_ENDPOINT When TLS Is Enabled

## Summary

When `services.minio.tls: true` and `services.minio.fqdn` is set, the generator
still writes `MINIO_ENDPOINT=https://<ip>:<port>` in `.envrc`. This causes TLS
certificate validation failures in any tool that uses `MINIO_ENDPOINT` to connect
to MinIO, because the cert has a DNS SAN (matching the FQDN) but not an IP SAN.

**Observed failure:** `mcli mb` in the otelcol `bucket.yml` role fails with:

```
x509: cannot validate certificate for <ip> because it doesn't contain any IP SANs
```

## Root Cause

`generate_envrc()` in `scripts/generate-configs.py` (around line 832):

```python
if m.get("ip"):
    # Always use IP — dev container cannot resolve internal FQDNs through Squid.
    scheme = "https" if minio_tls else "http"
    minio_endpoint = f'{scheme}://{_strip_prefix(m["ip"])}:{m.get("port", 9000)}'
```

The comment "always use IP" was written with the assumption that the MinIO TLS cert
would include an IP SAN. It does not — the cert is issued to the FQDN only.

## Inconsistency

The `otelcol_minio_endpoint` inventory var generated in the same script (around
line 674) already handles TLS correctly:

```python
if minio_tls and minio_fqdn:
    otelcol_endpoint = f"https://{minio_fqdn}:{minio_port}"
elif minio_ip:
    otelcol_endpoint = f"http://{minio_ip}:{minio_port}"
```

`MINIO_ENDPOINT` in `.envrc` needs the same logic.

## Proposed Fix

In `generate_envrc()`, replace the IP-always block with:

```python
if m.get("ip"):
    if minio_tls and minio_fqdn:
        minio_endpoint = f"https://{minio_fqdn}:{m.get('port', 9000)}"
    else:
        scheme = "https" if minio_tls else "http"
        minio_endpoint = f'{scheme}://{_strip_prefix(m["ip"])}:{m.get("port", 9000)}'
```

## DNS Resolution Concern

The original comment notes that the dev container may not resolve internal FQDNs.
This is a real concern: Squid proxies HTTP/HTTPS but bare TCP DNS is not proxied.

However, the dev container's DNS resolver is inherited from the Docker host, which
typically resolves the lab domain if the host has the internal DNS servers configured.
Verify with `dig <minio-fqdn>` inside the dev container before relying on hostname
resolution. If DNS is not available, the alternative is to add an IP SAN to the MinIO
cert at next renewal — but the generator fix is the correct long-term approach.

## Workaround (immediate)

Manually set `MINIO_ENDPOINT` in `.envrc` to the FQDN:

```bash
export MINIO_ENDPOINT="https://<minio-fqdn>:9000"
```

Re-run `direnv allow` after editing. Do not run `make configure` or it will be
overwritten with the IP-based value.

## Scope of Impact

- `mcli` calls in `ansible/roles/otelcol/tasks/bucket.yml` (confirmed failing)
- Any other role or script that reads `MINIO_ENDPOINT` and connects with TLS
- Terraform state backend is unaffected (uses a separate MinIO endpoint config
  with `insecure = true` in the S3 backend block)

## Files to Change

- `scripts/generate-configs.py` — `generate_envrc()` function, ~line 832
- After fix: run `make configure` and verify `.envrc` emits the FQDN
- Integration test: run `make configure` against both `sandbox.yml.example` and a
  config with `tls: false` to confirm both paths produce correct output
