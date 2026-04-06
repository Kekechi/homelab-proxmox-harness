## Requirements

No requirements.

## Providers

| Name | Version |
|------|---------|
| <a name="provider_proxmox"></a> [proxmox](#provider\_proxmox) | n/a |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [proxmox_virtual_environment_network_linux_bridge.this](https://registry.terraform.io/providers/hashicorp/proxmox/latest/docs/resources/virtual_environment_network_linux_bridge) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_bridge_address"></a> [bridge\_address](#input\_bridge\_address) | IPv4 address of the bridge in CIDR notation (e.g. '192.168.20.1/24'). Leave empty for L2-only bridge. | `string` | `null` | no |
| <a name="input_bridge_gateway"></a> [bridge\_gateway](#input\_bridge\_gateway) | IPv4 gateway for the bridge. Only needed if bridge\_address is set and this node routes the VLAN. | `string` | `null` | no |
| <a name="input_bridge_name"></a> [bridge\_name](#input\_bridge\_name) | Linux bridge interface name (e.g. 'vmbr1') | `string` | n/a | yes |
| <a name="input_comment"></a> [comment](#input\_comment) | Description shown in Proxmox UI | `string` | `""` | no |
| <a name="input_node_name"></a> [node\_name](#input\_node\_name) | Proxmox node on which to create the network bridge | `string` | n/a | yes |
| <a name="input_vlan_aware"></a> [vlan\_aware](#input\_vlan\_aware) | Whether the bridge is VLAN-aware (allows VM/LXC VLAN tagging) | `bool` | `true` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_bridge_name"></a> [bridge\_name](#output\_bridge\_name) | The Linux bridge interface name |
| <a name="output_node_name"></a> [node\_name](#output\_node\_name) | The Proxmox node this bridge is on |
