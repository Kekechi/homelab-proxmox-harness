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

variable "root_ca_bridge" {
  description = "Proxmox VNet bridge for the root CA VM"
  type        = string
}

variable "issuing_ca_bridge" {
  description = "Proxmox VNet bridge for the issuing CA LXC"
  type        = string
}

variable "dns_auth_bridge" {
  description = "Proxmox VNet bridge for the DNS auth+recursor LXC"
  type        = string
}

variable "dns_dist_bridge" {
  description = "Proxmox VNet bridge for the DNSdist LXC"
  type        = string
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
  description = "SSH public key to inject via cloud-init into provisioned VMs/LXCs. Required for the issuing CA LXC unless a root_password is passed directly to the module — the LXC module enforces at least one auth method at plan time."
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
  description = "LXC template file ID for all LXC containers. Format: '<storage>:vztmpl/<filename>'. Override in tfvars if your template storage is not 'local'. Verify exact filename with: pveam available --section system | grep debian"
  type        = string
  # Default assumes the template has been downloaded to local storage. Download first:
  #   pveam update && pveam download local debian-13-standard_13.0-1_amd64.tar.zst
  # Override in sandbox.tfvars if the filename or storage differs on your node.
  default = "local:vztmpl/debian-13-standard_13.0-1_amd64.tar.zst"
}

variable "domain_name" {
  description = "Internal domain name used in DNS output hints (e.g. 'lab.example.com'). Does not affect resource configuration — informational only. Override in tfvars; default is a placeholder."
  type        = string
  default     = "lab.example.com"
}

# ---------------------------------------------------------------------------
# DNS — PowerDNS Auth+Recursor (LXC) + DNSdist (LXC)
# ---------------------------------------------------------------------------

variable "dns_auth_ct_id" {
  description = "Proxmox container ID for the DNS Auth+Recursor LXC"
  type        = number
  default     = 103
}

variable "dns_auth_ipv4_address" {
  description = "Static IPv4 address (CIDR notation) for the DNS Auth LXC"
  type        = string
  default     = null
}

variable "dns_auth_ipv4_gateway" {
  description = "IPv4 gateway for the DNS Auth LXC"
  type        = string
  default     = null
}

variable "dns_dist_ct_id" {
  description = "Proxmox container ID for the DNSdist LXC"
  type        = number
  default     = 104
}

variable "dns_dist_ipv4_address" {
  description = "Static IPv4 address (CIDR notation) for the DNSdist LXC"
  type        = string
  default     = null
}

variable "dns_dist_ipv4_gateway" {
  description = "IPv4 gateway for the DNSdist LXC"
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Artifact Server — Nexus Repository CE (LXC)
# ---------------------------------------------------------------------------

variable "nexus_ct_id" {
  description = "Proxmox container ID for the Nexus Repository CE LXC"
  type        = number
  default     = 205
}

variable "nexus_ipv4_address" {
  description = "Static IPv4 address (CIDR notation) for the Nexus LXC, e.g. '192.168.50.20/24'"
  type        = string
  default     = null
}

variable "nexus_ipv4_gateway" {
  description = "IPv4 gateway for the Nexus LXC"
  type        = string
  default     = null
}

variable "nexus_bridge" {
  description = "Proxmox VNet bridge for the Nexus LXC. No default — generator always emits this from infrastructure.networks config."
  type        = string
}

