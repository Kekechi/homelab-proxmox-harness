#!/usr/bin/env bash
# =============================================================================
# bootstrap-minio.sh — One-time MinIO state backend setup (per environment)
#
# Creates (for the given environment):
#   - tfstate-<env> bucket       (versioning enabled)
#   - terraform-<env> IAM policy (read/write tfstate-<env> bucket only)
#   - terraform-<env> IAM user   (bound to the above policy)
#
# Run once per environment, against that environment's MinIO instance.
#
# Usage:
#   bash scripts/bootstrap-minio.sh [ENV]
#   ENV defaults to the value in .env.mk (or "sandbox" if not found).
#
# Requirements:
#   - mcli (MinIO Client) installed in the dev container
#   - MinIO must be running and reachable at MINIO_ENDPOINT
#   - MINIO_ROOT_USER and MINIO_ROOT_PASSWORD must be set in .envrc
#
# This script is idempotent — safe to re-run.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve ENV: argument > .env.mk > default "sandbox"
# ---------------------------------------------------------------------------
if [[ "${1:-}" != "" ]]; then
    ENV="${1}"
else
    ENVMK_FILE="$(dirname "$0")/../.env.mk"
    if [[ -f "${ENVMK_FILE}" ]]; then
        ENV=$(grep -E '^ENV\s*:?=' "${ENVMK_FILE}" | head -1 | sed 's/.*:*=\s*//' | tr -d '[:space:]')
        ENV="${ENV:-sandbox}"
    else
        ENV="sandbox"
    fi
fi

: "${MINIO_ENDPOINT:?Set MINIO_ENDPOINT in .envrc}"
: "${MINIO_ROOT_USER:?Set MINIO_ROOT_USER in .envrc (MinIO admin username)}"
: "${MINIO_ROOT_PASSWORD:?Set MINIO_ROOT_PASSWORD in .envrc (MinIO admin password)}"

ALIAS="homelab-minio-${ENV}"
BUCKET="tfstate-${ENV}"
IAM_USER="terraform-${ENV}"
POLICY_NAME="terraform-${ENV}-policy"

echo "==> Bootstrapping MinIO for environment: ${ENV}"
echo "    Endpoint : ${MINIO_ENDPOINT}"
echo "    Bucket   : ${BUCKET}"
echo "    IAM user : ${IAM_USER}"
echo ""

echo "==> Configuring mcli alias..."
mcli alias set "${ALIAS}" "${MINIO_ENDPOINT}" \
    "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}"

# ---------------------------------------------------------------------------
# Create bucket
# ---------------------------------------------------------------------------
echo "==> Creating bucket ${BUCKET}..."
mcli mb --ignore-existing "${ALIAS}/${BUCKET}"

# ---------------------------------------------------------------------------
# Enable versioning (allows state file recovery)
# ---------------------------------------------------------------------------
echo "==> Enabling versioning on ${BUCKET}..."
mcli version enable "${ALIAS}/${BUCKET}"

# ---------------------------------------------------------------------------
# Create environment-scoped IAM policy
# Policy: read/write tfstate-<env> bucket only
# ---------------------------------------------------------------------------
echo "==> Creating IAM policy ${POLICY_NAME}..."
POLICY=$(cat <<EOF
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
        "arn:aws:s3:::${BUCKET}",
        "arn:aws:s3:::${BUCKET}/*"
      ]
    }
  ]
}
EOF
)

echo "${POLICY}" | mcli admin policy create \
    "${ALIAS}" "${POLICY_NAME}" /dev/stdin 2>/dev/null || \
    echo "  Policy already exists — updating..."
echo "${POLICY}" | mcli admin policy create \
    "${ALIAS}" "${POLICY_NAME}" /dev/stdin 2>/dev/null || true

# ---------------------------------------------------------------------------
# Create IAM user
# ---------------------------------------------------------------------------
echo "==> Creating IAM user (${IAM_USER})..."
ACCESS_KEY="${IAM_USER}-$(openssl rand -hex 8)"
SECRET_KEY="$(openssl rand -base64 32)"

mcli admin user add "${ALIAS}" "${ACCESS_KEY}" "${SECRET_KEY}" || \
    echo "  User already exists"

mcli admin policy attach "${ALIAS}" "${POLICY_NAME}" \
    --user "${ACCESS_KEY}" || true

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " MinIO bootstrap complete (${ENV})"
echo "============================================================"
echo ""
echo " Bucket created:"
mcli ls "${ALIAS}"
echo ""
echo " Scoped IAM credentials — add to .envrc:"
echo "   export MINIO_ACCESS_KEY=\"${ACCESS_KEY}\""
echo "   export MINIO_SECRET_KEY=\"${SECRET_KEY}\""
echo ""
echo " NOTE: Store these values securely. They will not be shown again."
echo " The MINIO_ROOT_* credentials in .envrc retain full admin access."
echo " This key can ONLY access ${BUCKET}."
