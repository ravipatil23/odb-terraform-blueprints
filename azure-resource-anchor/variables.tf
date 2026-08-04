# Variable definitions. Real values go in terraform.tfvars.

variable "subscription_id" {
  description = "Azure subscription ID (used for provider auth)."
  type        = string
}

variable "resource_anchors" {
  description = "Map of Resource Anchors keyed by a short name. Add an entry to create another anchor."
  type = map(object({
    # ── required ──
    name                = string # anchor name
    resource_group_name = string # existing resource group the anchor maps to an OCI compartment

    # ── optional ──
    tags = optional(map(string), {})
  }))
  default = {}
}
