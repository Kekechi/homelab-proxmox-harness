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
#   bash components/minio/bootstrap.sh [ENV]
#   ENV defaults to the value in .env.mk (or "sandbox" if not found).
#
# Requirements:
#   - mcli (MinIO Client) installed on the controller host
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
    ENVMK_FILE="$(dirname "$0")/../../.env.mk"
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

# The provisioning play's "Restart minio" handler fires seconds before this
# script runs — probe readiness first or the mcli alias set races the restart
# (observed live: connection refused while the daemon was mid-restart).
echo "==> Waiting for MinIO readiness at ${MINIO_ENDPOINT} ..."
_ready_deadline=$(( $(date +%s) + 120 ))
until curl -sk -o /dev/null -w '%{http_code}' "${MINIO_ENDPOINT}/minio/health/live" 2>/dev/null | grep -q 200; do
    if (( $(date +%s) >= _ready_deadline )); then
        echo "ERROR: MinIO did not become healthy at ${MINIO_ENDPOINT} within 120s." >&2
        exit 1
    fi
    sleep 3
done
echo "    healthy."

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
# ---------------------------------------------------------------------------
# Persist the scoped credentials into .envrc
#
# Writing directly (rather than echoing for manual copy) is what makes the
# destroy→rebuild loop unattended: the next `make init` reads these straight
# from .envrc. .envrc is gitignored and the pre-commit guard blocks it, so the
# secret never leaves the dev container.
# ---------------------------------------------------------------------------
ENVRC_FILE="$(dirname "$0")/../../.envrc"
UPSERT="$(dirname "$0")/../../scripts/loop/envrc-upsert.py"
python3 "${UPSERT}" "${ENVRC_FILE}" MINIO_ACCESS_KEY "${ACCESS_KEY}"
python3 "${UPSERT}" "${ENVRC_FILE}" MINIO_SECRET_KEY "${SECRET_KEY}"

echo ""
echo "============================================================"
echo " MinIO bootstrap complete (${ENV})"
echo "============================================================"
echo ""
echo " Bucket created:"
mcli ls "${ALIAS}"
echo ""
echo " Scoped IAM credentials written to .envrc:"
echo "   MINIO_ACCESS_KEY  (access key id: ${ACCESS_KEY})"
echo "   MINIO_SECRET_KEY  (value hidden — stored in .envrc)"
echo ""
echo " Run 'direnv allow' (interactive shells) if the values are not yet"
echo " exported in your environment. Loop scripts source .envrc directly."
echo " This key can ONLY access ${BUCKET}; MINIO_ROOT_* retain admin access."
