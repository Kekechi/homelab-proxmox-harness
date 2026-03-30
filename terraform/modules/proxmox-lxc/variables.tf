variable "node_name" {
  description = "Proxmox node name on which to create the container"
  type        = string
}

variable "pool_id" {
  description = "Proxmox resource pool ID to assign the container to (e.g. 'sandbox')"
  type        = string
}

variable "hostname" {
  description = "Container hostname"
  type        = string
}

variable "vm_id" {
  description = "Proxmox container ID — must be unique cluster-wide"
  type        = number
}

variable "template_file_id" {
  description = "CT template file ID (e.g. 'local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst')"
  type        = string
}

variable "os_type" {
  description = "Container OS type (ubuntu, debian, centos, etc.)"
  type        = string
  default     = "ubuntu"
}

variable "cores" {
  description = "Number of CPU cores"
  type        = number
  default     = 1
}

variable "memory_mb" {
  description = "Dedicated RAM in MB"
  type        = number
  default     = 512
}

variable "swap_mb" {
  description = "Swap in MB"
  type        = number
  default     = 512
}

variable "disk_size_gb" {
  description = "Root disk size in GB"
  type        = number
  default     = 8
}

variable "datastore_id" {
  description = "Proxmox storage/datastore ID for the root disk"
  type        = string
  default     = "local-lvm"
}

variable "bridge" {
  description = "Network bridge to attach the primary NIC to"
  type        = string
  default     = "vmbr0"
}

variable "vlan_id" {
  description = "VLAN tag to apply to the primary NIC. Set to null for untagged."
  type        = number
  default     = null
}

variable "ipv4_address" {
  description = "Static IPv4 address in CIDR notation (e.g. '192.168.20.50/24'). Null = DHCP."
  type        = string
  default     = null
}

variable "ipv4_gateway" {
  description = "IPv4 default gateway. Required when ipv4_address is set."
  type        = string
  default     = null
}

variable "root_password" {
  description = "Root password for the container. Use SSH keys instead where possible."
  type        = string
  sensitive   = true
  default     = null
}

variable "tags" {
  description = "List of Proxmox tags to apply to the container"
  type        = list(string)
  default     = []
}

variable "start_on_boot" {
  description = "Whether to start the container automatically on Proxmox boot"
  type        = bool
  default     = true
}

variable "unprivileged" {
  description = "Whether to run the container as unprivileged (recommended)"
  type        = bool
  default     = true
}

variable "started" {
  description = "Whether the container should be started after creation"
  type        = bool
  default     = true
}

variable "description" {
  description = "Container description displayed in Proxmox UI"
  type        = string
  default     = null
}
