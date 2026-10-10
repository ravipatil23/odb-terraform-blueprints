# ─────────────────────────────────────────────────────────────────────────────
# DNS forwarding rules — standalone template
#
# Adds FORWARD rules to a VCN's DNS resolver, so databases in that VCN resolve
# named domains via a resolver elsewhere - on-prem, corporate, another cloud.
#
# The forwarding endpoint can go either way:
#
#   create_forwarder = false  (default) - the endpoint already exists, made by
#                              other tooling. You name it with
#                              source_endpoint_name and the rules point at it.
#
#   create_forwarder = true   - this template creates it too. Because Terraform
#                              then OWNS it, nsg_ids is just an argument -
#                              forwarder_nsg_ids attaches your NSG at creation,
#                              with no CLI step. Feed it nsg_id from the nsg
#                              template.
#
# ⚠ THIS TEMPLATE OWNS THE RESOLVER'S ENTIRE RULE LIST.
#
# The OCI API replaces the whole rules array on update - it does not append. Any
# rule currently on this resolver and not listed in var.rules is REMOVED on
# apply. That is unavoidable: the rules array is written as a unit. Read what is
# there first and bring across anything you need to keep:
#
#   oci dns resolver get --resolver-id <ocid> --scope PRIVATE --query 'data.rules'
#
# ⚠ The resolver is ADOPTED, not created. Resolvers are born with their VCN, so
# a plan saying "will be created" means Terraform is taking over the existing
# one; the real call is an update. Destroy does not delete it, but DOES clear
# these rules.
# ─────────────────────────────────────────────────────────────────────────────

# Creating an endpoint without somewhere to put it fails at the API with a less
# obvious message than this one.
check "forwarder_inputs_complete" {
  assert {
    condition     = !var.create_forwarder || var.forwarder_subnet_id != ""
    error_message = "create_forwarder = true needs forwarder_subnet_id - the subnet in the resolver's VCN that hosts the endpoint."
  }
}

# NSGs only take effect on an endpoint this template creates. Silently ignoring
# them against an existing endpoint would look like the attach had worked.
check "nsgs_only_when_creating" {
  assert {
    condition     = var.create_forwarder || length(var.forwarder_nsg_ids) == 0
    error_message = "forwarder_nsg_ids has no effect when create_forwarder is false - nsg_ids belongs to the endpoint, and this template does not manage an endpoint it did not create. Either set create_forwarder = true, or attach the NSG with the command the nsg template outputs."
  }
}

# ── The forwarding endpoint, when this template creates it ───────────────────
#
# Owning the endpoint is what makes nsg_ids settable here. Referencing someone
# else's endpoint cannot attach an NSG - nsg_ids is an attribute of the endpoint,
# and Terraform only sets attributes of resources it manages.
resource "oci_dns_resolver_endpoint" "forwarder" {
  count = var.create_forwarder ? 1 : 0

  resolver_id   = var.resolver_id
  name          = var.source_endpoint_name
  scope         = "PRIVATE"
  subnet_id     = var.forwarder_subnet_id
  is_forwarding = true
  is_listening  = false

  # The whole point of creating it here: attach the NSG declaratively.
  nsg_ids = length(var.forwarder_nsg_ids) > 0 ? var.forwarder_nsg_ids : null

  # Auto-assigned from the subnet when left empty.
  forwarding_address = var.forwarder_forwarding_address != "" ? var.forwarder_forwarding_address : null
}

# A rule naming an endpoint that is not on this resolver fails at the API. Catch
# the typo at plan time instead. data.oci_dns_resolver.this is in data.tf.
#
# Skipped when this template creates the endpoint - it does not exist yet at
# plan time, so there is nothing to find.
check "source_endpoint_exists" {
  assert {
    condition = var.create_forwarder || contains(
      [for e in data.oci_dns_resolver.this.endpoints : e.name],
      var.source_endpoint_name,
    )
    error_message = format(
      "No endpoint named %q on this resolver. Endpoints present: %s.",
      var.source_endpoint_name,
      join(", ", [for e in data.oci_dns_resolver.this.endpoints : e.name]),
    )
  }
}

resource "oci_dns_resolver" "this" {
  resolver_id = var.resolver_id
  scope       = "PRIVATE"

  # The rules reference the endpoint by NAME, which is a string - so nothing in
  # the graph tells Terraform the endpoint has to exist first. Without this the
  # rule can be written before the endpoint is created and the API rejects it.
  depends_on = [oci_dns_resolver_endpoint.forwarder]

  # Left null so the live resolver keeps whatever name it has — renaming shared
  # infrastructure as a side effect of adding a rule is rude.
  display_name = var.resolver_display_name != "" ? var.resolver_display_name : null

  # Inline blocks, so this is a plain dynamic block over your list rather than
  # iteration over resources. Order is preserved: OCI takes the first match.
  dynamic "rules" {
    for_each = var.rules
    content {
      action                    = "FORWARD"
      source_endpoint_name      = var.source_endpoint_name
      destination_addresses     = rules.value.destination_addresses
      qname_cover_conditions    = length(rules.value.qname_cover_conditions) > 0 ? rules.value.qname_cover_conditions : null
      client_address_conditions = length(rules.value.client_address_conditions) > 0 ? rules.value.client_address_conditions : null
    }
  }

  lifecycle {
    # scope is Optional + ForceNew and does not come back populated on import,
    # so state ends up empty against a config saying "PRIVATE" and Terraform
    # plans a REPLACEMENT - whose destroy half clears the live resolver's rules.
    ignore_changes = [scope]

    # Gate the rules on the endpoint actually being there, in BOTH modes.
    #
    # A precondition rather than a check block, because it has to run at the
    # right moment: preconditions are evaluated immediately before this resource
    # applies, which - thanks to depends_on above - is after the endpoint has
    # been created. A check block cannot do that; it reads the resolver at plan
    # time, when a to-be-created endpoint does not exist yet, which is why the
    # existence check block has to skip the create path entirely.
    #
    # It also errors rather than warns. A rule naming an endpoint that is not
    # there is rejected by the API, so there is nothing to be gained by letting
    # the apply proceed.
    precondition {
      condition = (
        var.create_forwarder
        ? oci_dns_resolver_endpoint.forwarder[0].state == "ACTIVE"
        : contains([for e in data.oci_dns_resolver.this.endpoints : e.name], var.source_endpoint_name)
      )
      error_message = (
        var.create_forwarder
        ? format("Forwarding endpoint %q was created but is not ACTIVE - the rules cannot reference it yet.", var.source_endpoint_name)
        : format("No endpoint named %q on this resolver. Endpoints present: %s.", var.source_endpoint_name, join(", ", [for e in data.oci_dns_resolver.this.endpoints : e.name]))
      )
    }
  }
}
