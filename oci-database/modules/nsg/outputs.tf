output "nsg_id" {
  description = "OCID of the network security group. This is the handle you attach to database VNICs or a subnet in OCI - this module creates the NSG but does not attach it."
  value       = oci_core_network_security_group.this.id
}

output "display_name" {
  description = "Display name of the NSG."
  value       = oci_core_network_security_group.this.display_name
}

output "rule_ids" {
  description = "Map of rule key to the created security rule's ID."
  value       = { for k, r in oci_core_network_security_group_security_rule.this : k => r.id }
}
