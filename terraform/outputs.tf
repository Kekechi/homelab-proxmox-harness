# Outputs from provisioned resources — generic maps keyed by service name.
# Consumed by operators/scripts via `terraform output -json`.

output "service_ids" {
  description = "Proxmox VM/CT id per provisioned service"
  value = merge(
    { for name, m in module.vm : name => m.vm_id },
    { for name, m in module.lxc : name => m.vm_id },
  )
}

output "service_addresses" {
  description = "Configured IPv4 address (CIDR) per provisioned service; null = DHCP"
  value       = { for name, svc in var.services : name => svc.ipv4_address }
}
