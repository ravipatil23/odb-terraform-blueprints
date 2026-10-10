variable "vcn_id" {
  type        = string
  description = "OCID of the VCN whose resolver gets the forwarder - the VCN the VM cluster sits in."
}

variable "resolver_id" {
  type        = string
  default     = null
  description = "OCID of that VCN's system resolver. Discovered from the VCN when null."
}

variable "endpoint_name" {
  type        = string
  description = "Name for the forwarding endpoint. Alphanumeric only - OCI rejects hyphens and underscores here."

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9]*$", var.endpoint_name))
    error_message = "endpoint_name must start with a letter and contain only letters and digits. OCI rejects hyphens, underscores and dots in resolver endpoint names."
  }
}

variable "subnet_id" {
  type        = string
  description = "OCID of the subnet that hosts the forwarding endpoint. Must be in the same VCN."
}

variable "forwarding_address" {
  type        = string
  default     = ""
  description = "Private IP for the endpoint. Auto-assigned from the subnet when empty."
}

variable "nsg_ids" {
  type        = list(string)
  default     = []
  description = "NSGs applied to the forwarding endpoint. Needs egress to the destination resolvers on port 53."
}

variable "resolver_display_name" {
  type        = string
  default     = ""
  description = "Rename the resolver. Empty leaves the existing name alone, which is usually what you want - this module adopts a resolver it did not create."
}

variable "rules" {
  description = <<-EOT
    FORWARD rules, keyed by a short name you choose. Every rule uses this
    module's forwarding endpoint as its source.

    Order matters: OCI evaluates rules in sequence and the FIRST match wins.
    Terraform iterates the map in key order, so name keys so that the intended
    precedence falls out alphabetically if you have overlapping domains.

    qname_cover_conditions lists the domains the rule matches - a domain covers
    its subdomains. An empty list matches everything, which is a catch-all and
    almost never what you want alongside other rules.
  EOT

  type = map(object({
    destination_addresses     = list(string)
    qname_cover_conditions    = optional(list(string), [])
    client_address_conditions = optional(list(string), [])
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, r in var.rules : length(r.destination_addresses) > 0
    ])
    error_message = "Each rule needs at least one entry in destination_addresses - the resolver IP queries are forwarded to."
  }
}
