variable "subscription_id" {
  description = "Azure subscription ID — used to build the parent resource-group ID."
  type        = string
}

variable "name" {
  description = "Anchor name. 3-24 chars, letters/numbers/hyphens."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]{3,24}$", var.name))
    error_message = "name must be 3-24 characters of letters, numbers or hyphens."
  }
}

variable "resource_group_name" {
  description = "Existing resource group that holds the anchor."
  type        = string
}

variable "location" {
  description = "Azure region. Must offer Oracle Base Database."
  type        = string
}

variable "resource_anchor_id" {
  description = "Azure resource ID of the Resource Anchor this one belongs to."
  type        = string
}

variable "subnet_id" {
  description = "Azure resource ID of the subnet delegated to Oracle.Database/networkAttachment."
  type        = string
}

variable "zones" {
  description = "Availability zone(s) the Base Database will reside in, e.g. [\"2\"]."
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ── Optional OCI-side settings ────────────────────────────────────────────────

variable "oci_vcn_dns_label" {
  description = "OCI VCN DNS label. Optional when DNS config is supplied."
  type        = string
  default     = ""
}

variable "oci_backup_cidr_block" {
  description = "OCI backup subnet CIDR. Not needed for Base Database."
  type        = string
  default     = ""
}

# ── DNS options ───────────────────────────────────────────────────────────────

variable "dns_listening_endpoint_enabled" {
  description = "Let Azure applications resolve database FQDNs."
  type        = bool
  default     = false
}

variable "dns_listening_allowed_cidrs" {
  description = "Comma-separated CIDRs allowed to query the listening endpoint."
  type        = string
  default     = ""
}

variable "dns_forwarding_endpoint_enabled" {
  description = "Let database instances resolve Azure private FQDNs."
  type        = bool
  default     = false
}

variable "dns_forwarding_rules" {
  description = "Forwarding rules applied when the forwarding endpoint is enabled."
  type = list(object({
    domain_names          = string # comma-separated
    forwarding_ip_address = string
  }))
  default = []
}

variable "dns_zone_sync_enabled" {
  description = "Replicate database private DNS zones from OCI into Azure."
  type        = bool
  default     = false
}
