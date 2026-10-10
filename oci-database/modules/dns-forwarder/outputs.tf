output "endpoint_name" {
  description = "Name of the forwarding endpoint. This is what the FORWARD rules reference as their source."
  value       = oci_dns_resolver_endpoint.forwarder.name
}

output "forwarding_address" {
  description = "Private IP assigned to the forwarding endpoint. Queries leave the VCN from this address — allow it at the destination resolver."
  value       = oci_dns_resolver_endpoint.forwarder.forwarding_address
}

output "endpoint_id" {
  description = "OCID of the forwarding endpoint."
  value       = oci_dns_resolver_endpoint.forwarder.id
}

output "resolver_id" {
  description = "OCID of the VCN resolver these rules were written to. Adopted, not created."
  value       = local.resolver_id
}

output "forwarded_domains" {
  description = "Domains forwarded, per rule key — a quick check that the rules landed as intended."
  value       = { for k, r in var.rules : k => r.qname_cover_conditions }
}
