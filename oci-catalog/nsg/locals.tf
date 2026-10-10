# All local variables are placed in this file.

locals {
  # Forwarding endpoints on the resolver, when one was supplied. Filtered on
  # is_forwarding because a resolver can also carry a LISTENING endpoint, and
  # attaching the NSG to the wrong one silently does nothing useful.
  forwarders = var.resolver_id == null ? [] : [
    for e in data.oci_dns_resolver.this[0].endpoints : e if e.is_forwarding
  ]

  # The endpoint the attach command targets. Null when no resolver was given, or
  # when the resolver has no forwarding endpoint - both handled in outputs.tf.
  forwarder_name = length(local.forwarders) > 0 ? local.forwarders[0].name : null

  # NSGs already on that endpoint. --nsg-ids REPLACES the list, so anything here
  # has to be carried into the command alongside the new NSG.
  forwarder_existing_nsg_ids = length(local.forwarders) > 0 ? coalesce(local.forwarders[0].nsg_ids, []) : []
}
