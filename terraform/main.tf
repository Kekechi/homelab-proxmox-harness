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
# All guests come from the generated `services` map (one entry per enabled
# service, kind = "vm" | "lxc"). Two static module blocks fan out over it —
# adding a service is a config/generator change, never a new module block.
# Every guest is pool-scoped (pool_id = var.pool_id) to enforce sandbox
# isolation.
# ---------------------------------------------------------------------------

module "vm" {
  source   = "./modules/proxmox-vm"
  for_each = { for name, svc in var.services : name => svc if svc.kind == "vm" }

  node_name              = each.value.node
  pool_id                = var.pool_id
  name                   = each.value.name
  vm_id                  = each.value.id
  clone_template_id      = each.value.clone_template_id
  cloudinit_datastore_id = var.cloudinit_datastore_id
  started                = each.value.started
  start_on_boot          = each.value.start_on_boot
  agent_enabled          = each.value.agent_enabled
  cores                  = each.value.cores
  cpu_type               = each.value.cpu_type
  memory_mb              = each.value.memory_mb
  disk_size_gb           = each.value.disk_size_gb
  datastore_id           = var.datastore_id
  bridge                 = each.value.bridge
  vlan_id                = null
  ipv4_address           = each.value.ipv4_address
  ipv4_gateway           = each.value.ipv4_gateway
  ssh_public_keys        = var.ssh_public_key != null ? [var.ssh_public_key] : []
  dns_servers            = var.dns_servers
}

module "lxc" {
  source   = "./modules/proxmox-lxc"
  for_each = { for name, svc in var.services : name => svc if svc.kind == "lxc" }

  node_name        = each.value.node
  pool_id          = var.pool_id
  name             = each.value.name
  vm_id            = each.value.id
  template_file_id = var.lxc_template_file_id
  os_type          = each.value.os_type
  unprivileged     = each.value.unprivileged
  started          = each.value.started
  start_on_boot    = each.value.start_on_boot
  cores            = each.value.cores
  memory_mb        = each.value.memory_mb
  swap_mb          = each.value.swap_mb
  disk_size_gb     = each.value.disk_size_gb
  data_disk_size   = each.value.data_disk_size
  data_disk_path   = each.value.data_disk_path
  datastore_id     = var.datastore_id
  bridge           = each.value.bridge
  vlan_id          = null
  ipv4_address     = each.value.ipv4_address
  ipv4_gateway     = each.value.ipv4_gateway
  ssh_public_keys  = var.ssh_public_key != null ? [var.ssh_public_key] : []
  dns_servers      = var.dns_servers
  nesting          = each.value.nesting
}

# ---------------------------------------------------------------------------
# State-address migration from the pre-for_each layout (one count-gated module
# block per service). Keep until both sandbox and production state have been
# applied once under the new addresses, then these can be deleted.
# ---------------------------------------------------------------------------

moved {
  from = module.root_ca[0]
  to   = module.vm["root_ca"]
}

moved {
  from = module.splunk[0]
  to   = module.vm["splunk"]
}

moved {
  from = module.issuing_ca[0]
  to   = module.lxc["issuing_ca"]
}

moved {
  from = module.dns_auth[0]
  to   = module.lxc["dns_auth"]
}

moved {
  from = module.dns_dist[0]
  to   = module.lxc["dns_dist"]
}

moved {
  from = module.nexus[0]
  to   = module.lxc["nexus"]
}

moved {
  from = module.log_server[0]
  to   = module.lxc["log_server"]
}
