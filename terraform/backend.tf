# =============================================================================
# Terraform Remote State Backend — MinIO (S3-compatible)
#
# Bucket is NOT hardcoded — pass it at init time:
#   Sandbox:    make init                (uses tfstate-sandbox)
#   Production: make init ENV=production (uses tfstate-production)
#
# Or directly:
#   terraform init \
#     -backend-config="bucket=tfstate-sandbox" \
#     -backend-config="access_key=$MINIO_ACCESS_KEY" \
#     -backend-config="secret_key=$MINIO_SECRET_KEY" \
#     -backend-config="endpoints={s3=\"$MINIO_ENDPOINT\"}"
#
# Endpoint SCHEME follows services.minio.tls (single source of truth):
#   - $MINIO_ENDPOINT is generated into .envrc by scripts/generate-configs.py:
#       minio.tls: false  -> http://<minio-ip>:<port>
#       minio.tls: true   -> https://<minio-fqdn>:<port>
#   The backend has no hardcoded scheme — it inherits whatever $MINIO_ENDPOINT
#   carries, so flipping minio.tls + `make configure` is sufficient. When tls is
#   true the S3 client must also trust the internal CA that signed the MinIO
#   server cert: the generator emits AWS_CA_BUNDLE=/workspace/.pki/root_ca.crt
#   into .envrc (Terraform's AWS SDK reads it). The MinIO server cert carries the
#   FQDN (primary SAN) + host IP (secondary SAN) so HTTPS validates either way.
#   `make init` additionally passes insecure=true as a belt-and-suspenders skip.
#
# Future migration to GitLab HTTP backend:
#   1. terraform state pull > backup.tfstate
#   2. Replace this block with:
#        backend "http" {
#          address        = "https://gitlab.example.com/api/v4/projects/<id>/terraform/state/<name>"
#          lock_address   = ".../lock"
#          unlock_address = ".../lock"
#          username       = "gitlab-token-user"
#          password       = var.gitlab_token
#          lock_method    = "POST"
#          unlock_method  = "DELETE"
#          retry_wait_min = 5
#        }
#   3. terraform init -migrate-state
# =============================================================================

terraform {
  backend "s3" {
    # bucket passed via -backend-config at init time
    key    = "terraform.tfstate"
    region = "us-east-1" # required but arbitrary for MinIO

    # Credentials and endpoint passed via -backend-config or env vars:
    # access_key = $MINIO_ACCESS_KEY
    # secret_key = $MINIO_SECRET_KEY
    # endpoints  = { s3 = $MINIO_ENDPOINT }

    use_path_style              = true # required for MinIO
    skip_credentials_validation = true # MinIO does not expose AWS validation
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true # avoids MinIO checksum issues (Terraform 1.6.1+)
  }
}
