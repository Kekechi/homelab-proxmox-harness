#!/usr/bin/env bash
# setup-vm-template-ubuntu2404.sh — Create an Ubuntu 24.04 cloud-init VM template on Proxmox
#
# Run this script ONCE on the Proxmox host (as root) before running Terraform.
# Terraform clones from this template when provisioning VMs that require Ubuntu.
#
# Usage:
#   bash scripts/setup-vm-template-ubuntu2404.sh
#
# Default storage is 'nfs-shared' for cluster-wide template access. All cluster
# nodes can clone from a template stored on shared NFS storage, so the script
# only needs to be run once on any cluster node.
#
# Single-node override: STORAGE=local-lvm bash scripts/setup-vm-template-ubuntu2404.sh
#
# Environment variables (optional):
#   TEMPLATE_VMID   VM ID for the template (default: 9001)
#   STORAGE         Proxmox storage ID for the disk (default: nfs-shared)
#                   Single-node setups: override with STORAGE=local-lvm
#   TEMPLATE_POOL   Proxmox pool to assign the template VM to after creation.
#                   Required when a scoped API token (e.g. terraform@pve!claude-sandbox)
#                   needs to clone the template — the token can only see VMs in pools
#                   it has ACL access to. Leave unset to skip pool assignment.
#   NEXUS_APT_URL   Base URL of a Nexus apt proxy repo for the Ubuntu noble suite,
#                   e.g. http://nexus.home.lab:8081/repository/ubuntu-noble-proxy
#                   When set, the image installs qemu-guest-agent from Nexus instead
#                   of Ubuntu's CDN — required when the Proxmox host has no direct
#                   internet access. Leave unset for internet-connected environments.
#
# The template is created with NO network interface. Terraform adds the correct
# bridge (net0) after cloning, keeping the template environment-agnostic and
# avoiding the need for bridge-level IAM permissions to clone it.
#
# After the script completes the template will appear in the Proxmox UI.
# It is safe to re-run if the VM ID is not already in use (the script will
# refuse to proceed if a VM with TEMPLATE_VMID already exists).

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
TEMPLATE_VMID="${TEMPLATE_VMID:-9001}"
STORAGE="${STORAGE:-nfs-shared}"
TEMPLATE_POOL="${TEMPLATE_POOL:-}"
NEXUS_APT_URL="${NEXUS_APT_URL:-}"
# NOTE: Using the `current` URL means the downloaded image may change on re-runs,
# producing a different template than the first run. For reproducible environments,
# pin to a specific release:
#   https://cloud-images.ubuntu.com/noble/YYYYMMDD/noble-server-cloudimg-amd64.img
# Release dates are listed at: https://cloud-images.ubuntu.com/noble/
#
# To verify the downloaded image set IMAGE_CHECKSUM to the SHA256 from:
#   https://cloud-images.ubuntu.com/noble/current/SHA256SUMS
# Example: IMAGE_CHECKSUM="sha256:abc123..."
IMAGE_URL="${IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
IMAGE_FILE="/tmp/noble-server-cloudimg-amd64.img"
IMAGE_CHECKSUM="${IMAGE_CHECKSUM:-}"  # optional — set to "sha256:<hash>" to verify after download
DISK_SIZE="8G"

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
if ! pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "${STORAGE}"; then
  echo "ERROR: Storage '${STORAGE}' not found on this node." >&2
  echo "       For single-node setups, run: STORAGE=local-lvm bash $0" >&2
  echo "       For cluster setups, configure NFS storage first. See docs/cluster-setup.md" >&2
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: This script must be run as root on the Proxmox host." >&2
  exit 1
fi

if ! command -v qm &>/dev/null; then
  echo "ERROR: 'qm' not found — run this script on a Proxmox VE host." >&2
  exit 1
fi

if ! command -v virt-customize &>/dev/null; then
  echo "ERROR: 'virt-customize' not found — install libguestfs-tools:" >&2
  echo "       apt install libguestfs-tools" >&2
  exit 1
fi

if qm status "${TEMPLATE_VMID}" &>/dev/null; then
  echo "ERROR: VM ${TEMPLATE_VMID} already exists. Choose a different TEMPLATE_VMID or" >&2
  echo "       destroy the existing VM first:  qm destroy ${TEMPLATE_VMID}" >&2
  exit 1
fi

echo "=== Ubuntu 24.04 cloud-init template setup ==="
echo "  VMID      : ${TEMPLATE_VMID}"
echo "  Storage   : ${STORAGE}"
echo "  Network   : none (NIC added by Terraform after clone)"
echo "  APT source: ${NEXUS_APT_URL:-"Ubuntu CDN (direct internet)"}"
echo ""

# ---------------------------------------------------------------------------
# Download image
# ---------------------------------------------------------------------------
if [[ -f "${IMAGE_FILE}" ]]; then
  echo "[1/8] Image already present at ${IMAGE_FILE}, skipping download."
else
  echo "[1/8] Downloading Ubuntu 24.04 server cloud image..."
  wget -q --show-progress -O "${IMAGE_FILE}" "${IMAGE_URL}"
fi

# ---------------------------------------------------------------------------
# Optional checksum verification
# ---------------------------------------------------------------------------
if [[ -n "${IMAGE_CHECKSUM}" ]]; then
  echo "[1/8+] Verifying image checksum..."
  ALGO="${IMAGE_CHECKSUM%%:*}"
  EXPECTED="${IMAGE_CHECKSUM#*:}"
  ACTUAL=$(${ALGO}sum "${IMAGE_FILE}" | awk '{print $1}')
  if [[ "${ACTUAL}" != "${EXPECTED}" ]]; then
    echo "ERROR: Checksum mismatch." >&2
    echo "  Expected: ${EXPECTED}" >&2
    echo "  Actual  : ${ACTUAL}" >&2
    rm -f "${IMAGE_FILE}"
    exit 1
  fi
  echo "       Checksum OK."
fi

# ---------------------------------------------------------------------------
# Install qemu-guest-agent into image
#
# virt-customize runs the image's own Ubuntu apt inside a SLIRP network
# namespace, so the image reaches the network through the Proxmox host's
# stack — no separate internet connection is needed inside the VM.
#
# NEXUS_APT_URL: when set, replaces sources.list before installing so apt
# fetches from the Nexus proxy instead of Ubuntu's CDN. The override is
# temporary — cloud-init overwrites sources.list on every VM's first boot,
# so clones are not affected.
# ---------------------------------------------------------------------------
echo "[2/8] Installing qemu-guest-agent into image..."
if [[ -n "${NEXUS_APT_URL}" ]]; then
  virt-customize -a "${IMAGE_FILE}" \
    --network \
    --run-command "echo 'deb ${NEXUS_APT_URL} noble main' > /etc/apt/sources.list" \
    --install qemu-guest-agent \
    --quiet
else
  virt-customize -a "${IMAGE_FILE}" \
    --network \
    --install qemu-guest-agent \
    --quiet
fi

# ---------------------------------------------------------------------------
# Create base VM
# ---------------------------------------------------------------------------
echo "[3/8] Creating VM ${TEMPLATE_VMID}..."
qm create "${TEMPLATE_VMID}" \
  --name "ubuntu-2404-cloudinit" \
  --memory 2048 \
  --cores 1 \
  --serial0 socket \
  --vga serial0 \
  --agent enabled=1 \
  --ostype l26

# ---------------------------------------------------------------------------
# Import and attach disk
# ---------------------------------------------------------------------------
echo "[4/8] Importing disk image into ${STORAGE}..."
qm importdisk "${TEMPLATE_VMID}" "${IMAGE_FILE}" "${STORAGE}"

echo "[5/8] Attaching disk as scsi0..."
DISK_REF=$(qm config "${TEMPLATE_VMID}" | awk -F': ' '/^unused0:/{print $2}')
if [[ -z "${DISK_REF}" ]]; then
  echo "ERROR: Could not find imported disk in VM ${TEMPLATE_VMID} config." >&2
  exit 1
fi
qm set "${TEMPLATE_VMID}" \
  --scsihw virtio-scsi-single \
  --scsi0 "${DISK_REF},discard=on,iothread=1"

# NOTE: If you want UEFI boot instead of BIOS, replace --ide2 with --scsi1 for
# the cloud-init drive and add --bios ovmf --efidisk0 ${STORAGE}:0,size=4M

# ---------------------------------------------------------------------------
# Cloud-init drive
# ---------------------------------------------------------------------------
echo "[6/8] Adding cloud-init drive on ide2..."
qm set "${TEMPLATE_VMID}" \
  --ide2 "${STORAGE}:cloudinit"

# ---------------------------------------------------------------------------
# Boot and resize
# ---------------------------------------------------------------------------
echo "[7/8] Configuring boot order and resizing disk to ${DISK_SIZE}..."
qm set "${TEMPLATE_VMID}" \
  --boot "order=scsi0" \
  --citype nocloud

qm resize "${TEMPLATE_VMID}" scsi0 "${DISK_SIZE}"

# ---------------------------------------------------------------------------
# Convert to template
# ---------------------------------------------------------------------------
echo "[8/8] Converting to template..."
qm template "${TEMPLATE_VMID}"

# ---------------------------------------------------------------------------
# Pool assignment (optional)
# ---------------------------------------------------------------------------
if [[ -n "${TEMPLATE_POOL}" ]]; then
  echo "[+] Assigning VM ${TEMPLATE_VMID} to pool '${TEMPLATE_POOL}'..."
  pvesh set "/pools/${TEMPLATE_POOL}" --vms "${TEMPLATE_VMID}"
  echo "    Done. Scoped API tokens with ACL access to /pool/${TEMPLATE_POOL} can now clone this template."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Template created successfully ==="
echo "  VM ID   : ${TEMPLATE_VMID}"
echo "  Name    : ubuntu-2404-cloudinit"
echo "  Disk    : ${STORAGE} / ${DISK_SIZE} (scsi0, discard=on, iothread=1)"
echo "  CI drive: ide2"
echo "  Network : none — Terraform adds net0 with the correct bridge after clone"
echo "  Pool    : ${TEMPLATE_POOL:-"(none — set TEMPLATE_POOL=<pool> if needed for IAM)"}"
echo ""
echo "Next step: run 'make plan' in the dev container to provision VMs from this template."
echo "  Terraform will clone VMID ${TEMPLATE_VMID} for Ubuntu 24.04 VMs."

# Clean up downloaded image
rm -f "${IMAGE_FILE}"
echo "  Cleaned up temporary image file."
