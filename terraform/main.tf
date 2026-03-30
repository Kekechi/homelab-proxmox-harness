# =============================================================================
# Proxmox Homelab — Terraform Root
#
# Sandbox:    Claude Code may run plan AND apply (plan-file required)
#             Credentials:  terraform@pve!claude-sandbox  (pool-scoped to /pool/sandbox)
#             State bucket: tfstate-sandbox
#
# Production: Claude Code may run plan ONLY — human operator applies
#             Credentials:  terraform@pve!operator-production  (NOT in dev container)
#             State bucket: tfstate-production
#
# Required workflow (sandbox):
#   terraform plan -var-file=sandbox.tfvars -out=sandbox.tfplan
#   terraform apply sandbox.tfplan
# =============================================================================

provider "proxmox" {
  # Reads from environment variables — do not hardcode credentials here:
  #   PROXMOX_VE_ENDPOINT  — Proxmox API URL
  #   PROXMOX_VE_API_TOKEN — API token (e.g. terraform@pve!claude-sandbox=...)
  #   PROXMOX_VE_INSECURE  — true for self-signed certificates
}

# ---------------------------------------------------------------------------
# Add module calls here as you provision resources.
# Keep resources pool-scoped (pool_id = var.pool_id) to enforce sandbox isolation.
# ---------------------------------------------------------------------------

# Example: sandbox test VM
# Uncomment and adjust when deploying a VM.
#
# module "test_vm" {
#   source = "./modules/proxmox-vm"
#
#   node_name         = var.proxmox_node
#   pool_id           = var.pool_id
#   vm_name           = "test-01"
#   vm_id             = var.vm_id_range_start
#   clone_template_id = var.clone_template_id
#   cores             = 2
#   memory_mb         = 2048
#   disk_size_gb      = 20
#   datastore_id      = var.datastore_id
#   bridge            = var.bridge
#   vlan_id           = var.vlan_id
#   ssh_public_key    = var.ssh_public_key
#   tags              = ["terraform", "managed"]
# }
