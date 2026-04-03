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

variable "cloudinit_datastore_id" {
  description = "Proxmox storage ID for cloud-init snippets. Must be a directory storage with Snippets content type enabled."
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
  default     = null
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
  default     = null
}

# ---------------------------------------------------------------------------
# PKI — Root CA (offline VM) + Issuing CA (LXC)
# ---------------------------------------------------------------------------

variable "root_ca_vm_id" {
  description = "Proxmox VM ID for the offline Root CA VM"
  type        = number
  default     = 201
}

variable "root_ca_ipv4_address" {
  description = "Static IPv4 address (CIDR notation) for the Root CA VM, e.g. '192.168.50.10/24'"
  type        = string
  default     = null
}

variable "root_ca_ipv4_gateway" {
  description = "IPv4 gateway for the Root CA VM"
  type        = string
  default     = null
}

variable "issuing_ca_ct_id" {
  description = "Proxmox container ID for the Issuing CA LXC"
  type        = number
  default     = 202
}

variable "issuing_ca_ipv4_address" {
  description = "Static IPv4 address (CIDR notation) for the Issuing CA LXC, e.g. '192.168.50.11/24'"
  type        = string
  default     = null
}

variable "issuing_ca_ipv4_gateway" {
  description = "IPv4 gateway for the Issuing CA LXC"
  type        = string
  default     = null
}

variable "cloud_init_template_id" {
  description = "VM ID of the Debian 13 cloud-init template to clone from (created by scripts/setup-vm-template.sh)"
  type        = number
  default     = 9000
}

variable "lxc_template_file_id" {
  description = "LXC template file ID for the Issuing CA container. Format: '<storage>:vztmpl/<filename>'. Override in tfvars if your template storage is not 'local'. Verify exact filename with: pveam available --section system | grep debian"
  type        = string
  default     = "local:vztmpl/debian-13-standard_13.0-1_amd64.tar.zst"
}

variable "domain_name" {
  description = "Internal domain name used in DNS output hints (e.g. 'lab.example.com'). Does not affect resource configuration — informational only."
  type        = string
  default     = "lab.example.com"
}

