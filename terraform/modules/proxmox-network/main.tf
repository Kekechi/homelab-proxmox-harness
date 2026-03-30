resource "proxmox_virtual_environment_network_linux_bridge" "this" {
  node_name = var.node_name
  name      = var.bridge_name
  comment   = var.comment

  address    = var.bridge_address
  gateway    = var.bridge_gateway
  vlan_aware = var.vlan_aware
}
