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

# ---------------------------------------------------------------------------
# PKI — two-tier internal certificate authority
#
# Root CA:    offline VM (started = false, start_on_boot = false).
#             Boot only when signing the intermediate CSR or rotating certs.
#             Bootstrap: scripts/setup-vm-template.sh must be run once on the
#             Proxmox host before Terraform apply to create the template VM.
#
# Issuing CA: always-on LXC serving ACME + JWK on port 9000 behind an nginx
#             TCP stream proxy on port 443.
# ---------------------------------------------------------------------------

module "root_ca" {
  source = "./modules/proxmox-vm"

  node_name          = var.proxmox_node
  pool_id            = var.pool_id
  vm_name            = "root-ca"
  vm_id              = var.root_ca_vm_id
  clone_template_id  = var.cloud_init_template_id
  started            = false
  start_on_boot      = false
  cores              = 1
  memory_mb          = 512
  disk_size_gb       = 8
  datastore_id       = var.datastore_id
  bridge             = var.bridge
  vlan_id            = var.vlan_id
  ipv4_address       = var.root_ca_ipv4_address
  ipv4_gateway       = var.root_ca_ipv4_gateway
  ssh_public_key     = var.ssh_public_key
  tags               = ["terraform", "pki", "root-ca"]
}

module "issuing_ca" {
  source = "./modules/proxmox-lxc"

  node_name        = var.proxmox_node
  pool_id          = var.pool_id
  hostname         = "issuing-ca"
  vm_id            = var.issuing_ca_ct_id
  template_file_id = var.lxc_template_file_id
  os_type          = "debian"
  unprivileged     = true
  started          = true
  start_on_boot    = true
  cores            = 1
  memory_mb        = 512
  disk_size_gb     = 8
  datastore_id     = var.datastore_id
  bridge           = var.bridge
  vlan_id          = var.vlan_id
  ipv4_address     = var.issuing_ca_ipv4_address
  ipv4_gateway     = var.issuing_ca_ipv4_gateway
  ssh_public_keys  = var.lxc_ssh_public_keys
  tags             = ["terraform", "pki", "issuing-ca"]
}
