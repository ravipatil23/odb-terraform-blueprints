output "exadata_lpg_id" {
  description = "OCID of the Exadata-side Local Peering Gateway - created here, or the existing one referenced."
  value       = local.exadata_lpg_id
}

output "hub_lpg_id" {
  description = "OCID of the Hub-side Local Peering Gateway - created here, or the existing one referenced."
  value       = local.hub_lpg_id
}

output "lpg_managed" {
  description = "Whether this module created the LPG pair (true) or referenced an existing peering (false)."
  value       = local.create_lpgs
}

output "forwarding_endpoint_name" {
  description = "Name of the Exadata VCN forwarding resolver endpoint."
  value       = oci_dns_resolver_endpoint.exadata_forward.name
}

output "forwarding_endpoint_ip" {
  description = "Private IP assigned to the Exadata forwarding resolver endpoint."
  value       = oci_dns_resolver_endpoint.exadata_forward.forwarding_address
}

output "peering_status" {
  description = "Status of the Exadata-side LPG peering toward the hub. \"EXISTING (unmanaged)\" when referencing a pre-existing pair - Terraform does not read its status, so verify it in the console or with the OCI CLI."
  value       = local.create_lpgs ? oci_core_local_peering_gateway.exadata[0].peering_status : "EXISTING (unmanaged)"
}

