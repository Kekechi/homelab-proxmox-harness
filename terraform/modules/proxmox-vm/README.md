## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | ~> 1.10.0 |
| <a name="requirement_proxmox"></a> [proxmox](#requirement\_proxmox) | ~> 0.99.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_proxmox"></a> [proxmox](#provider\_proxmox) | ~> 0.99.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [proxmox_virtual_environment_vm.this](https://registry.terraform.io/providers/bpg/proxmox/latest/docs/resources/virtual_environment_vm) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_bridge"></a> [bridge](#input\_bridge) | Network bridge to attach the primary NIC to (e.g. 'vmbr0') | `string` | `"vmbr0"` | no |
| <a name="input_clone_template_id"></a> [clone\_template\_id](#input\_clone\_template\_id) | VM ID of the template to clone from. Set to 0 to create from scratch. | `number` | `0` | no |
| <a name="input_cloudinit_datastore_id"></a> [cloudinit\_datastore\_id](#input\_cloudinit\_datastore\_id) | Proxmox storage ID for cloud-init snippets. Must be a directory storage with Snippets content type enabled. | `string` | n/a | yes |
| <a name="input_cores"></a> [cores](#input\_cores) | Number of CPU cores | `number` | `2` | no |
| <a name="input_datastore_id"></a> [datastore\_id](#input\_datastore\_id) | Proxmox storage/datastore ID for the root disk | `string` | `"local-lvm"` | no |
| <a name="input_disk_size_gb"></a> [disk\_size\_gb](#input\_disk\_size\_gb) | Root disk size in GB | `number` | `20` | no |
| <a name="input_ipv4_address"></a> [ipv4\_address](#input\_ipv4\_address) | Static IPv4 address in CIDR notation (e.g. '192.168.20.100/24'). Null = DHCP. | `string` | `null` | no |
| <a name="input_ipv4_gateway"></a> [ipv4\_gateway](#input\_ipv4\_gateway) | IPv4 default gateway. Required when ipv4\_address is set. | `string` | `null` | no |
| <a name="input_memory_mb"></a> [memory\_mb](#input\_memory\_mb) | Dedicated RAM in MB | `number` | `2048` | no |
| <a name="input_node_name"></a> [node\_name](#input\_node\_name) | Proxmox node name on which to create the VM | `string` | n/a | yes |
| <a name="input_pool_id"></a> [pool\_id](#input\_pool\_id) | Proxmox resource pool ID to assign the VM to (e.g. 'sandbox') | `string` | n/a | yes |
| <a name="input_ssh_public_key"></a> [ssh\_public\_key](#input\_ssh\_public\_key) | SSH public key injected via cloud-init for the default user | `string` | `null` | no |
| <a name="input_start_on_boot"></a> [start\_on\_boot](#input\_start\_on\_boot) | Whether to start the VM automatically on Proxmox boot | `bool` | `true` | no |
| <a name="input_started"></a> [started](#input\_started) | Whether the VM should be started after creation | `bool` | `true` | no |
| <a name="input_vlan_id"></a> [vlan\_id](#input\_vlan\_id) | VLAN tag to apply to the primary NIC. Set to null for untagged. | `number` | `null` | no |
| <a name="input_vm_id"></a> [vm\_id](#input\_vm\_id) | Proxmox VM ID — must be unique cluster-wide | `number` | n/a | yes |
| <a name="input_vm_name"></a> [vm\_name](#input\_vm\_name) | Name of the VM as displayed in Proxmox | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_ipv4_addresses"></a> [ipv4\_addresses](#output\_ipv4\_addresses) | IPv4 addresses reported by the QEMU guest agent (requires agent to be running) |
| <a name="output_vm_id"></a> [vm\_id](#output\_vm\_id) | Proxmox VM ID |
| <a name="output_vm_name"></a> [vm\_name](#output\_vm\_name) | VM name |
