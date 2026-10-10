variable "oci_region" {
  type        = string
  description = "OCI region, e.g. \"us-ashburn-1\"."
}

# Supplied directly rather than discovered from the VCN. The
# oci_core_vcn_dns_resolver_association lookup can return null instead of
# erroring - for a wrong region, or a VCN the credentials cannot see - and that
# surfaced as an opaque "coalesce failed: no non-null arguments" rather than
# anything actionable. Pasting the OCID is one more line and always tells the
# truth about what you are writing to.
#
#   oci dns resolver list --compartment-id <comp> --scope PRIVATE \
#     --query 'data[].{name:"display-name",id:id,vcn:"attached-vcn-id"}' --output table
variable "resolver_id" {
  type        = string
  description = "OCID of the VCN's system resolver the rules are written to (ocid1.dnsresolver...). The VCN the VM cluster sits in owns it."

  validation {
    condition     = can(regex("^ocid1\\.dnsresolver\\.", var.resolver_id))
    error_message = "Expected a resolver OCID starting ocid1.dnsresolver. A VCN OCID (ocid1.vcn) is not the same thing - find the resolver with: oci dns resolver list --compartment-id <comp> --scope PRIVATE"
  }
}

variable "source_endpoint_name" {
  type        = string
  description = "Name of the forwarding endpoint the rules send queries out of. When create_forwarder is false this must already exist - a check block confirms it. When true, it is the name given to the endpoint this template creates. Alphanumeric only; OCI rejects hyphens, underscores and dots."

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9]*$", var.source_endpoint_name))
    error_message = "source_endpoint_name must start with a letter and contain only letters and digits."
  }
}

# ── Creating the forwarding endpoint (optional) ───────────────────────────────
# Default is false: the endpoint already exists and is only referenced.
#
# Set true and this template creates it - which is the only way to attach an NSG
# from here. nsg_ids is an attribute of the endpoint, so Terraform can set it
# only on an endpoint it owns. Referencing someone else's leaves the attach as a
# manual CLI step (see the nsg template's forwarder_attach_command output).

variable "create_forwarder" {
  type        = bool
  default     = false
  description = "Create the forwarding endpoint rather than referencing an existing one. Requires forwarder_subnet_id. Enables forwarder_nsg_ids."
}

variable "forwarder_subnet_id" {
  type        = string
  default     = ""
  description = "Subnet that hosts the endpoint. Must be in the resolver's VCN. Required when create_forwarder is true, ignored otherwise."
}

variable "forwarder_nsg_ids" {
  type        = list(string)
  default     = []
  description = "NSGs attached to the endpoint at creation - e.g. nsg_id from the nsg template. Only applies when create_forwarder is true; an existing endpoint cannot be modified from here. The NSG needs egress on 53 to the rule destinations."
}

variable "forwarder_forwarding_address" {
  type        = string
  default     = ""
  description = "Private IP for the endpoint. Auto-assigned from the subnet when empty. Only applies when create_forwarder is true."
}

variable "resolver_display_name" {
  type        = string
  default     = ""
  description = "Rename the resolver. Empty leaves the existing name alone, which is usually what you want - this template adopts a resolver it did not create."
}

variable "rules" {
  description = <<-EOT
    FORWARD rules, in order. OCI evaluates them in sequence and the FIRST match
    wins, so put the most specific domains first.

    A list rather than a map: these are inline blocks on the resolver, so the
    order here is the order applied.

    qname_cover_conditions lists the domains a rule matches - a domain covers
    its subdomains. An empty list matches everything, which is a catch-all and
    almost never right alongside other rules.

    ⚠ This list REPLACES every rule on the resolver. Anything already there and
    not repeated here is removed.
  EOT

  type = list(object({
    destination_addresses     = list(string)
    qname_cover_conditions    = optional(list(string), [])
    client_address_conditions = optional(list(string), [])
  }))

  validation {
    condition     = length(var.rules) > 0
    error_message = "At least one rule is required. An empty list would clear every forwarding rule on the resolver - if that is what you want, do it deliberately with the OCI CLI."
  }

  validation {
    condition     = alltrue([for r in var.rules : length(r.destination_addresses) > 0])
    error_message = "Each rule needs at least one entry in destination_addresses - the resolver IP queries are forwarded to."
  }
}
