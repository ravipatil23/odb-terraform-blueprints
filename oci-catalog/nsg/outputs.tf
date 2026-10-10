output "nsg_id" {
  description = "OCID of the network security group. This template creates it but attaches it to nothing — see forwarder_attach_command below, and README.md for the VM cluster."
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

# ── Attaching to the DNS forwarding endpoint ─────────────────────────────────
# Only populated when resolver_id is set. The endpoint belongs to other tooling,
# so the attach is a command to run rather than something Terraform applies.

output "forwarder_name" {
  description = "Name of the forwarding endpoint found on the resolver, or null if resolver_id was not set or the resolver has no forwarding endpoint."
  value       = local.forwarder_name
}

output "forwarder_existing_nsg_ids" {
  description = "NSGs already attached to that endpoint. Empty when it has none — which is the usual case for a tooling-created forwarder."
  value       = local.forwarder_existing_nsg_ids
}

output "forwarder_attach_command" {
  description = "Ready-to-run OCI CLI command attaching this NSG to the forwarding endpoint. Run it once; --nsg-ids replaces the endpoint's list, so any NSG already there is carried through."

  value = (
    var.resolver_id == null
    ? "Set resolver_id in terraform.tfvars to generate the attach command."
    : local.forwarder_name == null
    ? format("No forwarding endpoint found on resolver %s. Check it has one: oci dns resolver get --resolver-id %s --scope PRIVATE --query 'data.endpoints'", var.resolver_id, var.resolver_id)
    : format(
      "oci dns resolver-endpoint update --resolver-id %s --resolver-endpoint-name %s --scope PRIVATE --force --nsg-ids '%s'",
      var.resolver_id,
      local.forwarder_name,
      jsonencode(distinct(concat(local.forwarder_existing_nsg_ids, [oci_core_network_security_group.this.id]))),
    )
  )
}
