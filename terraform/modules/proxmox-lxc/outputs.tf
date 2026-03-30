output "vm_id" {
  description = "Proxmox container ID"
  value       = proxmox_virtual_environment_container.this.vm_id
}

output "hostname" {
  description = "Container hostname"
  value       = proxmox_virtual_environment_container.this.initialization[0].hostname
}

output "network_interface_names" {
  description = "Names of the container's network interfaces (e.g. eth0)"
  value       = proxmox_virtual_environment_container.this.network_interface[*].name
}
