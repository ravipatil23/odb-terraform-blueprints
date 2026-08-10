output "id" {
  description = "Azure resource ID of the Network Anchor."
  value       = azapi_resource.this.id
}

output "name" {
  description = "Network Anchor name."
  value       = azapi_resource.this.name
}
