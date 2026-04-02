#!/usr/bin/env bash
# setup-vm-template.sh — Create a Debian 12 cloud-init VM template on Proxmox
#
# Run this script ONCE on the Proxmox host (as root) before running Terraform.
# Terraform clones from this template when provisioning the Root CA VM.
#
# Usage:
#   bash scripts/setup-vm-template.sh
#
# Environment variables (optional):
#   TEMPLATE_VMID   VM ID for the template (default: 9000)
#   STORAGE         Proxmox storage ID for the disk (default: local-lvm)
#   BRIDGE          Network bridge (default: vmbr0)
#
# After the script completes the template will appear in the Proxmox UI.
# It is safe to re-run if the VM ID is not already in use (the script will
# refuse to proceed if a VM with TEMPLATE_VMID already exists).

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
TEMPLATE_VMID="${TEMPLATE_VMID:-9000}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
# NOTE: Using the `latest` URL means the downloaded image may change on re-runs,
# producing a different template than the first run. For reproducible environments,
# pin to a specific snapshot:
#   https://cloud.debian.org/images/cloud/bookworm/<snapshot>/debian-12-genericcloud-amd64.qcow2
# Snapshot dates are listed at: https://cloud.debian.org/images/cloud/bookworm/
#
# To verify the downloaded image set IMAGE_CHECKSUM to the SHA512 from:
#   https://cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS
# Example: IMAGE_CHECKSUM="sha512:abc123..."
IMAGE_URL="${IMAGE_URL:-https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2}"
IMAGE_FILE="/tmp/debian-12-genericcloud-amd64.qcow2"
IMAGE_CHECKSUM="${IMAGE_CHECKSUM:-}"  # optional — set to "sha512:<hash>" to verify after download
DISK_SIZE="8G"

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: This script must be run as root on the Proxmox host." >&2
  exit 1
fi

if ! command -v qm &>/dev/null; then
  echo "ERROR: 'qm' not found — run this script on a Proxmox VE host." >&2
  exit 1
fi

if qm status "${TEMPLATE_VMID}" &>/dev/null; then
  echo "ERROR: VM ${TEMPLATE_VMID} already exists. Choose a different TEMPLATE_VMID or" >&2
  echo "       destroy the existing VM first:  qm destroy ${TEMPLATE_VMID}" >&2
  exit 1
fi

echo "=== Debian 12 cloud-init template setup ==="
echo "  VMID   : ${TEMPLATE_VMID}"
echo "  Storage: ${STORAGE}"
echo "  Bridge : ${BRIDGE}"
echo ""

# ---------------------------------------------------------------------------
# Download image
# ---------------------------------------------------------------------------
if [[ -f "${IMAGE_FILE}" ]]; then
  echo "[1/7] Image already present at ${IMAGE_FILE}, skipping download."
else
  echo "[1/7] Downloading Debian 12 genericcloud image..."
  wget -q --show-progress -O "${IMAGE_FILE}" "${IMAGE_URL}"
fi

# ---------------------------------------------------------------------------
# Create base VM
# ---------------------------------------------------------------------------
echo "[2/7] Creating VM ${TEMPLATE_VMID}..."
qm create "${TEMPLATE_VMID}" \
  --name "debian-12-cloudinit" \
  --memory 2048 \
  --cores 1 \
  --net0 "virtio,bridge=${BRIDGE}" \
  --serial0 socket \
  --vga serial0 \
  --agent enabled=1 \
  --ostype l26

# ---------------------------------------------------------------------------
# Import and attach disk
# ---------------------------------------------------------------------------
echo "[3/7] Importing disk image into ${STORAGE}..."
qm importdisk "${TEMPLATE_VMID}" "${IMAGE_FILE}" "${STORAGE}"

echo "[4/7] Attaching disk as scsi0..."
qm set "${TEMPLATE_VMID}" \
  --scsihw virtio-scsi-single \
  --scsi0 "${STORAGE}:vm-${TEMPLATE_VMID}-disk-0,discard=on,iothread=1"

# NOTE: If you want UEFI boot instead of BIOS, replace --ide2 with --scsi1 for
# the cloud-init drive and add --bios ovmf --efidisk0 ${STORAGE}:0,size=4M

# ---------------------------------------------------------------------------
# Cloud-init drive
# ---------------------------------------------------------------------------
echo "[5/7] Adding cloud-init drive on ide2..."
qm set "${TEMPLATE_VMID}" \
  --ide2 "${STORAGE}:cloudinit"

# ---------------------------------------------------------------------------
# Boot and resize
# ---------------------------------------------------------------------------
echo "[6/7] Configuring boot order and resizing disk to ${DISK_SIZE}..."
qm set "${TEMPLATE_VMID}" \
  --boot "order=scsi0" \
  --citype nocloud

qm resize "${TEMPLATE_VMID}" scsi0 "${DISK_SIZE}"

# ---------------------------------------------------------------------------
# Convert to template
# ---------------------------------------------------------------------------
echo "[7/7] Converting to template..."
qm template "${TEMPLATE_VMID}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Template created successfully ==="
echo "  VM ID   : ${TEMPLATE_VMID}"
echo "  Name    : debian-12-cloudinit"
echo "  Disk    : ${STORAGE} / ${DISK_SIZE} (scsi0, discard=on, iothread=1)"
echo "  CI drive: ide2"
echo "  Bridge  : ${BRIDGE}"
echo ""
echo "Next step: run 'make plan' in the dev container to provision the PKI VMs."
echo "  Terraform will clone VMID ${TEMPLATE_VMID} for the Root CA VM."

# Clean up downloaded image
rm -f "${IMAGE_FILE}"
echo "  Cleaned up temporary image file."
