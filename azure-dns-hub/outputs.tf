output "hub_listening_endpoint_ip" {
  description = "Private IP of the hub LISTENING endpoint. Point Azure's DNS forwarding ruleset at this address; every spoke's FORWARD rule already targets it. Created here unless create_hub_listening_endpoint is false, in which case it is the supplied or discovered address of the anchor's own endpoint."
  value       = local.hub_listening_ip
}

output "hub_listening_endpoint_name" {
  description = "Name of the hub LISTENING endpoint created here, or null when the anchor's endpoint is being consumed instead."
  value       = one(oci_dns_resolver_endpoint.hub_listening[*].name)
}

# No hub forwarding endpoint output: that one IS the Network Anchor's - it comes
# from isOracleDnsForwardingEndpointEnabled and is not a resource of this
# configuration. Read its address from the anchor or the OCI console.

output "attached_views_by_environment" {
  description = "Private view OCIDs per environment. These are pre-existing views, referenced not created."
  value       = { for k, e in var.environments : k => e.view_ids }
}

output "attached_views" {
  description = "Flat, deduplicated list of every private view attached to the hub resolver."
  value       = local.attached_view_ids
}

output "hub_resolver_rules" {
  description = "The full rule list sent to the hub resolver - rules preserved from the resolver (the Network Anchor's, typically) followed by those declared in hub_resolver_forward_rules. Empty when hub_resolver_forward_rules is empty, in which case the resolver's rules are not managed here at all."
  value       = local.hub_resolver_rules
}

output "hub_resolver_rules_preserved" {
  description = "Rules read from the live hub resolver and carried through unchanged - what would have been deleted had the rule list been declared without preserve_unmanaged_hub_resolver_rules. Check this before the first apply that declares a rule."
  value       = local.unmanaged_hub_rules
}

output "links" {
  description = "Per-environment wiring details (LPGs + forwarding endpoint)."
  value = {
    for k, m in module.link : k => {
      exadata_lpg_id           = m.exadata_lpg_id
      hub_lpg_id               = m.hub_lpg_id
      lpg_managed              = m.lpg_managed
      forwarding_endpoint_ip   = m.forwarding_endpoint_ip
      forwarding_endpoint_name = m.forwarding_endpoint_name
      peering_status           = m.peering_status
    }
  }
}
