variable "oci_region" {
  type        = string
  description = "OCI region, e.g. \"us-ashburn-1\"."
}

variable "compartment_id" {
  type        = string
  sensitive   = true
  description = "OCID of the compartment the NSG is created in."
}

variable "vcn_id" {
  type        = string
  description = "OCID of the VCN the NSG belongs to - the VCN the VM cluster sits in."
}

variable "display_name" {
  type        = string
  description = "Display name for the NSG."
}

# Optional. Supply it and the outputs include a ready-to-run command that
# attaches this NSG to the VCN's DNS forwarding endpoint.
#
# The resolver and its endpoints are created by other tooling, so this template
# does not manage them - nsg_ids lives ON the endpoint, and Terraform can only
# set an attribute of a resource it owns. Rather than adopt someone else's
# endpoint, the attach is emitted as a command you run once.
#
#   oci dns resolver list --compartment-id <comp> --scope PRIVATE \
#     --query 'data[].{name:"display-name",id:id,vcn:"attached-vcn-id"}' --output table
variable "resolver_id" {
  type        = string
  default     = null
  description = "OCID of the VCN's DNS resolver (ocid1.dnsresolver...). Optional - only used to locate the forwarding endpoint and build the attach command."

  validation {
    condition     = var.resolver_id == null || can(regex("^ocid1\\.dnsresolver\\.", var.resolver_id))
    error_message = "Expected a resolver OCID starting ocid1.dnsresolver, or null to skip the attach command."
  }
}

variable "freeform_tags" {
  type        = map(string)
  default     = {}
  description = "Freeform tags applied to the NSG."
}

variable "rules" {
  description = <<-EOT
    Security rules, keyed by a short name you choose. The key names the rule in
    state - renaming it destroys and recreates that rule.

    direction decides which side is read: INGRESS uses source/source_type,
    EGRESS uses destination/destination_type.

    protocol is the IANA number as a string - "6" TCP, "17" UDP, "1" ICMP, or
    "all". min_port/max_port apply to TCP and UDP only; omit both to allow every
    port, or give min_port alone for a single port.
  EOT

  type = map(object({
    direction   = string
    protocol    = optional(string, "6")
    description = optional(string, "")
    stateless   = optional(bool, false)

    source      = optional(string)
    source_type = optional(string, "CIDR_BLOCK")

    destination      = optional(string)
    destination_type = optional(string, "CIDR_BLOCK")

    min_port = optional(number)
    max_port = optional(number)

    icmp_type = optional(number)
    icmp_code = optional(number)
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, r in var.rules : contains(["INGRESS", "EGRESS"], r.direction)
    ])
    error_message = "Each rule's direction must be exactly \"INGRESS\" or \"EGRESS\"."
  }

  validation {
    condition = alltrue([
      for k, r in var.rules :
      r.direction == "INGRESS" ? r.source != null : r.destination != null
    ])
    error_message = "INGRESS rules require source; EGRESS rules require destination."
  }

  validation {
    condition = alltrue([
      for k, r in var.rules : r.max_port == null || r.min_port != null
    ])
    error_message = "max_port without min_port is not a range. Set min_port too, or omit both to allow all ports."
  }

  validation {
    condition = alltrue([
      for k, r in var.rules :
      r.min_port == null || r.max_port == null || r.max_port >= r.min_port
    ])
    error_message = "max_port must be greater than or equal to min_port."
  }
}
