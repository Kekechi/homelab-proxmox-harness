# Design item: MinIO-TLS state-backend cold-start bootstrapping

**Status:** open — surfaced during the deployment-verification-layer session (WS4c). Needs a `/design` pass before a cold-start `minio.tls:true` is attempted.

## Problem

The shared MinIO instance is **both** the internal-CA-issued TLS service **and** the Terraform state backend. Enabling TLS on it (`minio.tls: true`) creates a bootstrapping paradox in the destroy→rebuild loop:

- The MinIO cert is issued by the internal issuing CA (step-ca).
- The issuing CA is Terraform-managed, so it only exists **after** `terraform apply`.
- `terraform apply` needs the state backend (MinIO) to be reachable at the **`init`** step, which runs *before* the CA is deployed.

So on a cold start: MinIO comes up with no CA available → its TLS task correctly **skips** certificate issuance → MinIO serves plain HTTP → but the generated backend config expects HTTPS → `init` fails.

The MinIO role's documented flow is therefore **day-2**: deploy MinIO over HTTP → bring up PKI → re-run the MinIO role to add TLS. That works, but it is not a single cold-start loop pass.

## What already exists (committed)

The generator wiring and the cert self-heal are in place and correct for the day-2 flow:
- HTTPS endpoint + S3-client CA-bundle trust + dual (FQDN + IP) cert SAN, emitted only when `minio.tls` is true.
- MinIO cert renewer converted to the oneshot+timer self-heal pattern (renew, with re-enroll fallback past expiry).

## Options to evaluate in the /design pass

1. **Self-signed bootstrap cert.** MinIO serves a self-signed cert immediately; the loop's `init` connects with cert-verification disabled; once PKI is up, the cert is re-enrolled to a CA-issued one and the backend re-validates. Trades a brief unverified-cert window at init for a single-pass cold start.
2. **Two-phase backend migration.** Cold start runs the backend over HTTP; after PKI is up, the MinIO role adds TLS and the backend is re-`init`-ed over HTTPS. No single green pass, but no unverified-cert window.
3. **CA-before-state-backend.** Stand up the issuing CA outside the Terraform-managed path so it exists before the state backend needs TLS. Larger architectural change.

Decision criteria: trust posture (is an init-time unverified cert acceptable in this isolated path?), how faithfully the loop must model the production HTTPS state bucket, and complexity.
