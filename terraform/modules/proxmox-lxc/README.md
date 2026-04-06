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
| [proxmox_virtual_environment_container.this](https://registry.terraform.io/providers/bpg/proxmox/latest/docs/resources/virtual_environment_container) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_bridge"></a> [bridge](#input\_bridge) | Network bridge to attach the primary NIC to | `string` | `"vmbr0"` | no |
| <a name="input_cores"></a> [cores](#input\_cores) | Number of CPU cores | `number` | `1` | no |
| <a name="input_datastore_id"></a> [datastore\_id](#input\_datastore\_id) | Proxmox storage/datastore ID for the root disk | `string` | `"local-lvm"` | no |
| <a name="input_description"></a> [description](#input\_description) | Container description displayed in Proxmox UI | `string` | `null` | no |
| <a name="input_disk_size_gb"></a> [disk\_size\_gb](#input\_disk\_size\_gb) | Root disk size in GB | `number` | `8` | no |
| <a name="input_hostname"></a> [hostname](#input\_hostname) | Container hostname | `string` | n/a | yes |
| <a name="input_ipv4_address"></a> [ipv4\_address](#input\_ipv4\_address) | Static IPv4 address in CIDR notation (e.g. '192.168.20.50/24'). Null = DHCP. | `string` | `null` | no |
| <a name="input_ipv4_gateway"></a> [ipv4\_gateway](#input\_ipv4\_gateway) | IPv4 default gateway. Required when ipv4\_address is set. | `string` | `null` | no |
| <a name="input_memory_mb"></a> [memory\_mb](#input\_memory\_mb) | Dedicated RAM in MB | `number` | `512` | no |
| <a name="input_node_name"></a> [node\_name](#input\_node\_name) | Proxmox node name on which to create the container | `string` | n/a | yes |
| <a name="input_os_type"></a> [os\_type](#input\_os\_type) | Container OS type (ubuntu, debian, centos, etc.) | `string` | `"ubuntu"` | no |
| <a name="input_pool_id"></a> [pool\_id](#input\_pool\_id) | Proxmox resource pool ID to assign the container to (e.g. 'sandbox') | `string` | n/a | yes |
| <a name="input_root_password"></a> [root\_password](#input\_root\_password) | Root password for the container. Use SSH keys instead where possible. | `string` | `null` | no |
| <a name="input_ssh_public_keys"></a> [ssh\_public\_keys](#input\_ssh\_public\_keys) | List of SSH public keys to inject into the container's root account | `list(string)` | `[]` | no |
| <a name="input_start_on_boot"></a> [start\_on\_boot](#input\_start\_on\_boot) | Whether to start the container automatically on Proxmox boot | `bool` | `true` | no |
| <a name="input_started"></a> [started](#input\_started) | Whether the container should be started after creation | `bool` | `true` | no |
| <a name="input_swap_mb"></a> [swap\_mb](#input\_swap\_mb) | Swap in MB | `number` | `512` | no |
| <a name="input_template_file_id"></a> [template\_file\_id](#input\_template\_file\_id) | CT template file ID (e.g. 'local:vztmpl/ubuntu-24.04-standard\_24.04-2\_amd64.tar.zst') | `string` | n/a | yes |
| <a name="input_unprivileged"></a> [unprivileged](#input\_unprivileged) | Whether to run the container as unprivileged (recommended) | `bool` | `true` | no |
| <a name="input_vlan_id"></a> [vlan\_id](#input\_vlan\_id) | VLAN tag to apply to the primary NIC. Set to null for untagged. | `number` | `null` | no |
| <a name="input_vm_id"></a> [vm\_id](#input\_vm\_id) | Proxmox container ID — must be unique cluster-wide | `number` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_hostname"></a> [hostname](#output\_hostname) | Container hostname |
| <a name="output_network_interface_names"></a> [network\_interface\_names](#output\_network\_interface\_names) | Names of the container's network interfaces (e.g. eth0) |
| <a name="output_vm_id"></a> [vm\_id](#output\_vm\_id) | Proxmox container ID |
