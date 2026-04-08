# Outputs from provisioned resources
# Add outputs here as module calls are activated in main.tf.
# Outputs are consumed by Ansible inventory, other modules, or operator scripts.

# Example (uncomment when test_vm module is active):
# output "vm_id" {
#   description = "Provisioned VM ID"
#   value       = module.test_vm.vm_id
# }
#
# output "vm_ipv4" {
#   description = "Provisioned VM IPv4 address (requires qemu-guest-agent)"
#   value       = module.test_vm.ipv4_addresses
# }

# ---------------------------------------------------------------------------
# PKI outputs
# ---------------------------------------------------------------------------

output "root_ca_vm_id" {
  description = "Proxmox VM ID of the offline Root CA"
  value       = module.root_ca.vm_id
}

output "issuing_ca_ct_id" {
  description = "Proxmox container ID of the Issuing CA LXC"
  value       = module.issuing_ca.vm_id
}

output "pki_dns_records" {
  description = "DNS A records to add to DNS for PKI hosts. IPs are null when DHCP is configured — set root_ca_ipv4_address / issuing_ca_ipv4_address in tfvars to populate."
  value = {
    "root-ca" = {
      ip     = var.root_ca_ipv4_address
      record = "root-ca.${var.domain_name}"
    }
    "ca" = {
      ip     = var.issuing_ca_ipv4_address
      record = "ca.${var.domain_name}"
    }
  }
}

# ---------------------------------------------------------------------------
# DNS outputs
# ---------------------------------------------------------------------------

output "dns_auth_ct_id" {
  description = "Proxmox container ID of the DNS Auth+Recursor LXC"
  value       = module.dns_auth.vm_id
}

output "dns_dist_ct_id" {
  description = "Proxmox container ID of the DNSdist LXC"
  value       = module.dns_dist.vm_id
}
