variable "node_name" {
  description = "Proxmox node name on which to create the VM"
  type        = string
}

variable "pool_id" {
  description = "Proxmox resource pool ID to assign the VM to (e.g. 'sandbox')"
  type        = string
}

variable "vm_name" {
  description = "Name of the VM as displayed in Proxmox"
  type        = string
}

variable "vm_id" {
  description = "Proxmox VM ID — must be unique cluster-wide"
  type        = number
}

variable "clone_template_id" {
  description = "VM ID of the template to clone from. Set to 0 to create from scratch."
  type        = number
  default     = 0
}

variable "cores" {
  description = "Number of CPU cores"
  type        = number
  default     = 2
}

variable "memory_mb" {
  description = "Dedicated RAM in MB"
  type        = number
  default     = 2048
}

variable "disk_size_gb" {
  description = "Root disk size in GB"
  type        = number
  default     = 20
}

variable "datastore_id" {
  description = "Proxmox storage/datastore ID for the root disk"
  type        = string
  default     = "local-lvm"
}

variable "bridge" {
  description = "Network bridge to attach the primary NIC to (e.g. 'vmbr0')"
  type        = string
  default     = "vmbr0"
}

variable "vlan_id" {
  description = "VLAN tag to apply to the primary NIC. Set to null for untagged."
  type        = number
  default     = null
}

variable "ipv4_address" {
  description = "Static IPv4 address in CIDR notation (e.g. '192.168.20.100/24'). Null = DHCP."
  type        = string
  default     = null
}

variable "ipv4_gateway" {
  description = "IPv4 default gateway. Required when ipv4_address is set."
  type        = string
  default     = null
}

variable "ssh_public_key" {
  description = "SSH public key injected via cloud-init for the default user"
  type        = string
  default     = null
}

variable "tags" {
  description = "List of Proxmox tags to apply to the VM"
  type        = list(string)
  default     = []
}

variable "started" {
  description = "Whether the VM should be started after creation"
  type        = bool
  default     = true
}
