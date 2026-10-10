# ─────────────────────────────────────────────────────────────────────────────
# dns-forwarder — forwarding endpoint + FORWARD rules on a VCN's DNS resolver
#
# Lets databases in the VCN resolve names held elsewhere: an on-premises zone, a
# corporate resolver, or another cloud's private DNS. Two pieces:
#
#   1. a FORWARDING resolver endpoint on the VCN - the source of the queries
#   2. FORWARD rules on that same resolver - which domains go where
#
# The resolver itself is NOT created. Every VCN is born with one, and this
# module adopts it to add the rules. See the two warnings below before using.
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 6.0.0"
    }
  }
}

# The VCN's system resolver. Supply it explicitly, or let it be discovered.
data "oci_core_vcn_dns_resolver_association" "this" {
  vcn_id = var.vcn_id
}

locals {
  resolver_id = coalesce(var.resolver_id, data.oci_core_vcn_dns_resolver_association.this.dns_resolver_id)
}

resource "oci_dns_resolver_endpoint" "forwarder" {
  resolver_id   = local.resolver_id
  name          = var.endpoint_name
  scope         = "PRIVATE"
  subnet_id     = var.subnet_id
  is_forwarding = true
  is_listening  = false

  # forwarding_address is auto-assigned from the subnet when omitted.
  forwarding_address = var.forwarding_address != "" ? var.forwarding_address : null
  nsg_ids            = length(var.nsg_ids) > 0 ? var.nsg_ids : null
}

# ── FORWARD rules on the EXISTING resolver ───────────────────────────────────
#
# ⚠ THIS RESOURCE IS AUTHORITATIVE OVER `rules`.
#
# It does not append. The OCI API replaces the whole rule array with what is
# declared here, so any rule already on this resolver and not listed in
# var.rules is REMOVED on apply. Before first use, check what is there:
#
#   oci dns resolver get --resolver-id <ocid> --scope PRIVATE --query 'data.rules'
#
# and bring any rule you want to keep into var.rules.
#
# ⚠ It also cannot CREATE a resolver - resolvers are born with their VCN. A plan
# showing "will be created" means Terraform is adopting the existing one; the
# real operation is an update. Destroy likewise does not delete it, but DOES
# clear these rules.
resource "oci_dns_resolver" "this" {
  resolver_id = local.resolver_id
  scope       = "PRIVATE"

  # Left null by default so the live resolver keeps whatever name it has -
  # renaming shared infrastructure as a side effect of adding a rule is rude.
  display_name = var.resolver_display_name != "" ? var.resolver_display_name : null

  dynamic "rules" {
    for_each = var.rules
    content {
      action                 = "FORWARD"
      source_endpoint_name   = oci_dns_resolver_endpoint.forwarder.name
      destination_addresses  = rules.value.destination_addresses
      qname_cover_conditions = length(rules.value.qname_cover_conditions) > 0 ? rules.value.qname_cover_conditions : null

      # Restricts the rule to queries from these source CIDRs. Omitted means it
      # applies to every client in the VCN.
      client_address_conditions = length(rules.value.client_address_conditions) > 0 ? rules.value.client_address_conditions : null
    }
  }

  lifecycle {
    # scope is Optional + ForceNew and does not come back populated when this
    # resolver is imported - state ends up empty against a config saying
    # "PRIVATE", which plans a REPLACEMENT. The destroy half of that clears the
    # live resolver's rules. resolver_id identifies it on its own, so ignoring
    # scope drift removes the trigger at no cost.
    ignore_changes = [scope]
  }
}
