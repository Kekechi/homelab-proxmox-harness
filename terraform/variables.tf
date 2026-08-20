# =============================================================================
# Root variables — unified across environments (sandbox is the superset).
# All values come from the GENERATED terraform/<env>.tfvars (make configure);
# never hand-edit the tfvars.
# =============================================================================

# ---------------------------------------------------------------------------
# Shared infrastructure
# ---------------------------------------------------------------------------

variable "pool_id" {
  description = "Proxmox resource pool ID all guests are scoped to (isolation boundary)"
  type        = string
}

variable "datastore_id" {
  description = "Proxmox storage/datastore ID for root disks"
  type        = string
  default     = "local-lvm"
}

variable "cloudinit_datastore_id" {
  description = "Proxmox storage ID for cloud-init disks (must have 'images' content)"
  type        = string
}

variable "lxc_template_file_id" {
  description = "CT template file ID used by every LXC (e.g. 'shared-templates:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst')"
  type        = string
  default     = null
}

variable "ssh_public_key" {
  description = "SSH public key injected into every guest via cloud-init / LXC init"
  type        = string
  default     = null
}

variable "dns_servers" {
  description = "DNS resolver IPs injected into every guest's initialization block. Empty list = inherit Proxmox host defaults."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Services — one entry per enabled Terraform-managed guest.
# Emitted by scripts/genconfig (emit/tfvars.py) from config/<env>.yml.
# kind selects the module; kind-specific fields are ignored by the other kind.
# ---------------------------------------------------------------------------

variable "services" {
  description = "All Terraform-managed guests, keyed by service name (map key is the state address key: module.vm[\"<key>\"] / module.lxc[\"<key>\"])"
  type = map(object({
    kind          = string           # "vm" | "lxc"
    node          = string           # Proxmox node name
    id            = number           # cluster-unique VM/CT id
    name          = string           # VM name / container hostname
    bridge        = string           # network bridge for the primary NIC
    ipv4_address  = optional(string) # CIDR notation; null = DHCP
    ipv4_gateway  = optional(string)
    cores         = optional(number, 1)
    memory_mb     = optional(number, 512)
    disk_size_gb  = optional(number, 8)
    started       = optional(bool, true)
    start_on_boot = optional(bool, true)

    # vm-only
    clone_template_id = optional(number, 0)
    agent_enabled     = optional(bool, true)
    cpu_type          = optional(string, "x86-64-v2-AES")

    # lxc-only
    os_type        = optional(string, "debian")
    swap_mb        = optional(number, 512)
    unprivileged   = optional(bool, true)
    nesting        = optional(bool, true)
    data_disk_size = optional(string) # e.g. "20G"; null = no second disk
    data_disk_path = optional(string, "/mnt/data")
  }))
  default = {}

  validation {
    condition     = alltrue([for svc in values(var.services) : contains(["vm", "lxc"], svc.kind)])
    error_message = "services.*.kind must be \"vm\" or \"lxc\"."
  }
}
