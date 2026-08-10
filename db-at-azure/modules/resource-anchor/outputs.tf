output "id" {
  description = "Azure resource ID — wire this into a Network Anchor's resource_anchor_id."
  value       = azurerm_oracle_resource_anchor.this.id
}

output "location" {
  description = "Region the anchor inherited from its resource group (service-assigned)."
  value       = azurerm_oracle_resource_anchor.this.location
}

output "linked_compartment_id" {
  description = "OCID of the OCI compartment this anchor is linked to (service-assigned)."
  value       = azurerm_oracle_resource_anchor.this.linked_compartment_id
}
