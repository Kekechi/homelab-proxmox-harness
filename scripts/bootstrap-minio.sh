#!/usr/bin/env bash
# =============================================================================
# bootstrap-minio.sh — One-time MinIO state backend setup
#
# Creates:
#   - tfstate-sandbox bucket  (Claude's scoped key: read/write sandbox bucket only)
#   - tfstate-production bucket (operator's full-admin key)
#   - Versioning enabled on both (state file recovery)
#   - IAM policy + user for sandbox-scoped access key
#
# Requirements:
#   - mc (MinIO Client) installed: https://dl.min.io/client/mc/release/linux-amd64/mc
#   - MinIO must be running and reachable at MINIO_ENDPOINT
#   - MINIO_ADMIN_ACCESS_KEY and MINIO_ADMIN_SECRET_KEY must be set (operator creds)
#
# Run from host or dev container (MinIO must be reachable).
# This script is idempotent.
# =============================================================================

set -euo pipefail

: "${MINIO_ENDPOINT:?Set MINIO_ENDPOINT (e.g. http://192.168.20.5:9000)}"
: "${MINIO_ADMIN_ACCESS_KEY:?Set MINIO_ADMIN_ACCESS_KEY (MinIO admin/root key)}"
: "${MINIO_ADMIN_SECRET_KEY:?Set MINIO_ADMIN_SECRET_KEY (MinIO admin/root secret)}"

ALIAS="homelab-minio"
SANDBOX_BUCKET="tfstate-sandbox"
PRODUCTION_BUCKET="tfstate-production"
SANDBOX_USER="terraform-sandbox"

echo "==> Configuring mc alias..."
mc alias set "${ALIAS}" "${MINIO_ENDPOINT}" \
    "${MINIO_ADMIN_ACCESS_KEY}" "${MINIO_ADMIN_SECRET_KEY}"

# ---------------------------------------------------------------------------
# Create buckets
# ---------------------------------------------------------------------------
echo "==> Creating buckets..."
mc mb --ignore-existing "${ALIAS}/${SANDBOX_BUCKET}"
mc mb --ignore-existing "${ALIAS}/${PRODUCTION_BUCKET}"

# ---------------------------------------------------------------------------
# Enable versioning (allows state file recovery)
# ---------------------------------------------------------------------------
echo "==> Enabling versioning..."
mc version enable "${ALIAS}/${SANDBOX_BUCKET}"
mc version enable "${ALIAS}/${PRODUCTION_BUCKET}"

# ---------------------------------------------------------------------------
# Create sandbox-scoped IAM policy
# Policy: read/write tfstate-sandbox bucket only
# Claude Code uses a key bound to this policy.
# ---------------------------------------------------------------------------
echo "==> Creating sandbox IAM policy..."
SANDBOX_POLICY=$(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": [
        "arn:aws:s3:::tfstate-sandbox",
        "arn:aws:s3:::tfstate-sandbox/*"
      ]
    }
  ]
}
EOF
)

echo "${SANDBOX_POLICY}" | mc admin policy create \
    "${ALIAS}" "terraform-sandbox-policy" /dev/stdin || \
    echo "  Policy already exists — updating..."
echo "${SANDBOX_POLICY}" | mc admin policy create \
    "${ALIAS}" "terraform-sandbox-policy" /dev/stdin 2>/dev/null || true

# ---------------------------------------------------------------------------
# Create sandbox IAM user
# ---------------------------------------------------------------------------
echo "==> Creating sandbox IAM user (${SANDBOX_USER})..."
SANDBOX_ACCESS_KEY="${SANDBOX_USER}-$(openssl rand -hex 8)"
SANDBOX_SECRET_KEY="$(openssl rand -base64 32)"

mc admin user add "${ALIAS}" "${SANDBOX_ACCESS_KEY}" "${SANDBOX_SECRET_KEY}" || \
    echo "  User already exists"

mc admin policy attach "${ALIAS}" "terraform-sandbox-policy" \
    --user "${SANDBOX_ACCESS_KEY}" || true

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " MinIO bootstrap complete"
echo "============================================================"
echo ""
echo " Buckets created:"
mc ls "${ALIAS}"
echo ""
echo " Sandbox-scoped IAM credentials (add to .envrc):"
echo "   export MINIO_ACCESS_KEY=\"${SANDBOX_ACCESS_KEY}\""
echo "   export MINIO_SECRET_KEY=\"${SANDBOX_SECRET_KEY}\""
echo ""
echo " NOTE: Store these values securely. They will not be shown again."
echo " The operator's admin key (MINIO_ADMIN_*) retains full access to all buckets."
echo ""
echo " Production state bucket (${PRODUCTION_BUCKET}) requires the admin key."
echo " Claude's sandbox key CANNOT access ${PRODUCTION_BUCKET}."
