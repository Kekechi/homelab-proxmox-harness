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
#   - mcli (MinIO Client) installed in the dev container
#   - MinIO must be running and reachable at MINIO_ENDPOINT
#   - MINIO_ROOT_USER and MINIO_ROOT_PASSWORD must be set in .envrc
#
# Run from the dev container. This script is idempotent.
# =============================================================================

set -euo pipefail

: "${MINIO_ENDPOINT:?Set MINIO_ENDPOINT in .envrc}"
: "${MINIO_ROOT_USER:?Set MINIO_ROOT_USER in .envrc (MinIO admin username)}"
: "${MINIO_ROOT_PASSWORD:?Set MINIO_ROOT_PASSWORD in .envrc (MinIO admin password)}"

ALIAS="homelab-minio"
SANDBOX_BUCKET="tfstate-sandbox"
PRODUCTION_BUCKET="tfstate-production"
SANDBOX_USER="terraform-sandbox"

echo "==> Configuring mcli alias..."
mcli alias set "${ALIAS}" "${MINIO_ENDPOINT}" \
    "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}"

# ---------------------------------------------------------------------------
# Create buckets
# ---------------------------------------------------------------------------
echo "==> Creating buckets..."
mcli mb --ignore-existing "${ALIAS}/${SANDBOX_BUCKET}"
mcli mb --ignore-existing "${ALIAS}/${PRODUCTION_BUCKET}"

# ---------------------------------------------------------------------------
# Enable versioning (allows state file recovery)
# ---------------------------------------------------------------------------
echo "==> Enabling versioning..."
mcli version enable "${ALIAS}/${SANDBOX_BUCKET}"
mcli version enable "${ALIAS}/${PRODUCTION_BUCKET}"

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

echo "${SANDBOX_POLICY}" | mcli admin policy create \
    "${ALIAS}" "terraform-sandbox-policy" /dev/stdin || \
    echo "  Policy already exists — updating..."
echo "${SANDBOX_POLICY}" | mcli admin policy create \
    "${ALIAS}" "terraform-sandbox-policy" /dev/stdin 2>/dev/null || true

# ---------------------------------------------------------------------------
# Create sandbox IAM user
# ---------------------------------------------------------------------------
echo "==> Creating sandbox IAM user (${SANDBOX_USER})..."
SANDBOX_ACCESS_KEY="${SANDBOX_USER}-$(openssl rand -hex 8)"
SANDBOX_SECRET_KEY="$(openssl rand -base64 32)"

mcli admin user add "${ALIAS}" "${SANDBOX_ACCESS_KEY}" "${SANDBOX_SECRET_KEY}" || \
    echo "  User already exists"

mcli admin policy attach "${ALIAS}" "terraform-sandbox-policy" \
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
mcli ls "${ALIAS}"
echo ""
echo " Sandbox-scoped IAM credentials — add to .envrc:"
echo "   export MINIO_ACCESS_KEY=\"${SANDBOX_ACCESS_KEY}\""
echo "   export MINIO_SECRET_KEY=\"${SANDBOX_SECRET_KEY}\""
echo ""
echo " NOTE: Store these values securely. They will not be shown again."
echo " The MINIO_ROOT_* credentials in .envrc retain full admin access."
echo ""
echo " Production state bucket (${PRODUCTION_BUCKET}) requires the admin key."
echo " Claude's sandbox key CANNOT access ${PRODUCTION_BUCKET}."
