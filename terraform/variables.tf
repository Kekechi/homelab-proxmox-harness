variable "proxmox_node" {
  description = "Proxmox node name to deploy resources on"
  type        = string
}

variable "pool_id" {
  description = "Proxmox resource pool ID. Use 'sandbox' for sandbox deployments (Claude-scoped token only has ACL on /pool/sandbox). Set to '' if the target environment does not use pool isolation."
  type        = string
  default     = "sandbox"
}

variable "datastore_id" {
  description = "Proxmox storage/datastore ID for VM and LXC disks"
  type        = string
}

variable "bridge" {
  description = "Linux bridge to attach VMs/LXCs to"
  type        = string
  default     = "vmbr0"
}

variable "vlan_id" {
  description = "VLAN tag for the network. Set to null for untagged."
  type        = number
  default     = null
}

variable "network_cidr" {
  description = "CIDR of the target network (informational — used in docs and Squid ACL reference)"
  type        = string
  default     = ""
}

variable "vm_id_range_start" {
  description = "Starting VM ID for provisioned VMs. Increment for each additional VM to avoid conflicts."
  type        = number
  default     = 200
}

variable "clone_template_id" {
  description = "VM ID of the cloud-init template to clone from. 0 = create from scratch (no clone)."
  type        = number
  default     = 0
}

variable "ssh_public_key" {
  description = "SSH public key to inject via cloud-init into provisioned VMs/LXCs"
  type        = string
  default     = ""
}
