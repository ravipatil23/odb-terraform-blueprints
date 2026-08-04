output "resource_anchors" {
  description = "Resource Anchor details keyed by the resource_anchors map key."
  value = { for k, v in azurerm_oracle_resource_anchor.this : k => {
    id                    = v.id
    location              = v.location
    linked_compartment_id = v.linked_compartment_id
  } }
}
