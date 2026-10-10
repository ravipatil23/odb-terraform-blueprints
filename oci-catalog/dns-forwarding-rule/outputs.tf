output "resolver_id" {
  description = "OCID of the VCN resolver the rules were written to. Adopted, not created."
  value       = var.resolver_id
}

output "rules_before_apply" {
  description = "Rules that were on the resolver when this ran — read before your list replaced them. Check this the first time: anything here and missing from var.rules has been removed."
  value       = data.oci_dns_resolver.this.rules
}

# ── The forwarding endpoint ──────────────────────────────────────────────────
# Populated only when create_forwarder = true. Null otherwise, because the
# endpoint then belongs to other tooling and this template only names it.

output "forwarder_id" {
  description = "OCID of the forwarding endpoint created here, or null when referencing an existing one."
  value       = var.create_forwarder ? oci_dns_resolver_endpoint.forwarder[0].id : null
}

output "forwarder_forwarding_address" {
  description = "Private IP the endpoint sends queries from — allow it at the destination resolvers. Null when referencing an existing endpoint; read that one's address from the resolver instead."
  value       = var.create_forwarder ? oci_dns_resolver_endpoint.forwarder[0].forwarding_address : null
}

output "forwarder_nsg_ids" {
  description = "NSGs attached to the endpoint. Only set when this template created it — attaching to an existing endpoint is a CLI step, see the nsg template."
  value       = var.create_forwarder ? oci_dns_resolver_endpoint.forwarder[0].nsg_ids : null
}
