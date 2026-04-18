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
  count  = var.enable_pki ? 1 : 0
  source = "./modules/proxmox-vm"

  node_name              = var.root_ca_node
  pool_id                = var.pool_id
  vm_name                = "root-ca"
  vm_id                  = var.root_ca_vm_id
  clone_template_id      = var.cloud_init_template_id
  cloudinit_datastore_id = var.cloudinit_datastore_id
  started                = false
  start_on_boot          = false
  agent_enabled          = false
  cores                  = 1
  memory_mb              = 512
  disk_size_gb           = 8
  datastore_id           = var.datastore_id
  bridge                 = var.root_ca_bridge
  vlan_id                = null
  ipv4_address           = var.root_ca_ipv4_address
  ipv4_gateway           = var.root_ca_ipv4_gateway
  ssh_public_key         = var.ssh_public_key
  dns_servers            = var.dns_servers
}

module "issuing_ca" {
  count  = var.enable_pki ? 1 : 0
  source = "./modules/proxmox-lxc"

  node_name        = var.issuing_ca_node
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
  bridge           = var.issuing_ca_bridge
  vlan_id          = null
  ipv4_address     = var.issuing_ca_ipv4_address
  ipv4_gateway     = var.issuing_ca_ipv4_gateway
  ssh_public_keys  = var.ssh_public_key != null ? [var.ssh_public_key] : []
  dns_servers      = var.dns_servers
}

# ---------------------------------------------------------------------------
# DNS — PowerDNS Auth+Recursor + DNSdist
#
# dns-auth:  Auth (loopback:5300) + Recursor (LAN:53), colocated per
#            official migration guide. Not client-facing.
# dns-dist:  DNSdist — client-facing: plain DNS :53, DoT :853, DoH :443.
#            Single advertised resolver via DHCP.
# ---------------------------------------------------------------------------

module "dns_auth" {
  count  = var.enable_dns ? 1 : 0
  source = "./modules/proxmox-lxc"

  node_name        = var.dns_auth_node
  pool_id          = var.pool_id
  hostname         = "dns-auth"
  vm_id            = var.dns_auth_ct_id
  template_file_id = var.lxc_template_file_id
  os_type          = "debian"
  unprivileged     = true
  started          = true
  start_on_boot    = true
  cores            = 1
  memory_mb        = 512
  disk_size_gb     = 8
  datastore_id     = var.datastore_id
  bridge           = var.dns_auth_bridge
  vlan_id          = null
  ipv4_address     = var.dns_auth_ipv4_address
  ipv4_gateway     = var.dns_auth_ipv4_gateway
  ssh_public_keys  = var.ssh_public_key != null ? [var.ssh_public_key] : []
  dns_servers      = var.dns_servers
}

module "dns_dist" {
  count  = var.enable_dns ? 1 : 0
  source = "./modules/proxmox-lxc"

  node_name        = var.dns_dist_node
  pool_id          = var.pool_id
  hostname         = "dns-dist"
  vm_id            = var.dns_dist_ct_id
  template_file_id = var.lxc_template_file_id
  os_type          = "debian"
  unprivileged     = true
  started          = true
  start_on_boot    = true
  cores            = 1
  memory_mb        = 512
  disk_size_gb     = 8
  datastore_id     = var.datastore_id
  bridge           = var.dns_dist_bridge
  vlan_id          = null
  ipv4_address     = var.dns_dist_ipv4_address
  ipv4_gateway     = var.dns_dist_ipv4_gateway
  ssh_public_keys  = var.ssh_public_key != null ? [var.ssh_public_key] : []
  dns_servers      = var.dns_servers
}

# ---------------------------------------------------------------------------
# Artifact Server — Nexus Repository CE
#
# Provides APT proxy, OCI registry, and Terraform provider registry.
# Always-on on MGMT segment; LXC chosen over VM (JVM needs no virt).
# Secondary disk (20G) holds Nexus data dir, karaf.data, and tmpdir.
# ---------------------------------------------------------------------------

module "nexus" {
  count  = var.enable_nexus ? 1 : 0
  source = "./modules/proxmox-lxc"

  node_name        = var.nexus_node
  pool_id          = var.pool_id
  hostname         = "nexus-server"
  vm_id            = var.nexus_ct_id
  template_file_id = var.lxc_template_file_id
  os_type          = "debian"
  unprivileged     = true
  started          = true
  start_on_boot    = true
  cores            = 2
  memory_mb        = 8192
  disk_size_gb     = 8
  data_disk_size   = "20G"
  data_disk_path   = "/mnt/nexus-data"
  datastore_id     = var.datastore_id
  bridge           = var.nexus_bridge
  vlan_id          = null
  ipv4_address     = var.nexus_ipv4_address
  ipv4_gateway     = var.nexus_ipv4_gateway
  ssh_public_keys  = var.ssh_public_key != null ? [var.ssh_public_key] : []
  dns_servers      = var.dns_servers
}

# ---------------------------------------------------------------------------
# Log Server — OTel Collector
#
# Permanent always-on LXC for centralized log aggregation.
# Syslog receiver listens on port 1514 (not 514 — unprivileged LXC
# cannot bind ports < 1024). All syslog sources target port 1514.
# ---------------------------------------------------------------------------

module "log_server" {
  count  = var.enable_log_server ? 1 : 0
  source = "./modules/proxmox-lxc"

  node_name        = var.log_server_node
  pool_id          = var.pool_id
  hostname         = "log-server"
  vm_id            = var.log_server_ct_id
  template_file_id = var.lxc_template_file_id
  os_type          = "debian"
  unprivileged     = true
  started          = true
  start_on_boot    = true
  cores            = 1
  memory_mb        = 1024
  disk_size_gb     = 100
  datastore_id     = var.datastore_id
  bridge           = var.log_server_bridge
  vlan_id          = null
  ipv4_address     = var.log_server_ipv4_address
  ipv4_gateway     = var.log_server_ipv4_gateway
  ssh_public_keys  = var.ssh_public_key != null ? [var.ssh_public_key] : []
  dns_servers      = var.dns_servers
}
