variable "node_name" {
  description = "Proxmox node on which to create the network bridge"
  type        = string
}

variable "bridge_name" {
  description = "Linux bridge interface name (e.g. 'vmbr1')"
  type        = string
}

variable "comment" {
  description = "Description shown in Proxmox UI"
  type        = string
  default     = ""
}

variable "bridge_address" {
  description = "IPv4 address of the bridge in CIDR notation (e.g. '192.168.20.1/24'). Leave empty for L2-only bridge."
  type        = string
  default     = null
}

variable "bridge_gateway" {
  description = "IPv4 gateway for the bridge. Only needed if bridge_address is set and this node routes the VLAN."
  type        = string
  default     = null
}

variable "vlan_aware" {
  description = "Whether the bridge is VLAN-aware (allows VM/LXC VLAN tagging)"
  type        = bool
  default     = true
}
