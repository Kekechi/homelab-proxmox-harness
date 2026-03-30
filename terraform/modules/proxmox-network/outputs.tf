output "bridge_name" {
  description = "The Linux bridge interface name"
  value       = proxmox_virtual_environment_network_linux_bridge.this.name
}

output "node_name" {
  description = "The Proxmox node this bridge is on"
  value       = proxmox_virtual_environment_network_linux_bridge.this.node_name
}
