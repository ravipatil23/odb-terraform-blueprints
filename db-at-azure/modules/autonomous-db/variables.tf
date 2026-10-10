variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "name" {
  description = "Azure resource name for the Autonomous Database."
  type        = string
}

variable "display_name" {
  description = "Display name shown in the OCI console."
  type        = string
}

variable "db_workload" {
  description = "OLTP (transaction processing), DW (data warehouse), AJD (JSON) or APEX."
  type        = string
  default     = "OLTP"
  validation {
    condition     = contains(["OLTP", "DW", "AJD", "APEX"], var.db_workload)
    error_message = "db_workload must be OLTP, DW, AJD or APEX."
  }
}

# Free-form on purpose. 19c and 23ai are the values Oracle publishes for
# Serverless today; leaving it unvalidated means a newer release needs a tfvars
# edit, not a code change.
variable "db_version" {
  description = "Autonomous Database version, e.g. 19c or 23ai."
  type        = string
  default     = "23ai"
}

variable "license_model" {
  type    = string
  default = "LicenseIncluded"
  validation {
    condition     = contains(["LicenseIncluded", "BringYourOwnLicense"], var.license_model)
    error_message = "license_model must be LicenseIncluded or BringYourOwnLicense."
  }
}

variable "compute_model" {
  description = "ECPU is the current model; OCPU is legacy."
  type        = string
  default     = "ECPU"
  validation {
    condition     = contains(["ECPU", "OCPU"], var.compute_model)
    error_message = "compute_model must be ECPU or OCPU."
  }
}

variable "compute_count" {
  description = "ECPUs allocated. Minimum 2 for ECPU; fractional values allowed."
  type        = number
  default     = 2
}

variable "data_storage_size_in_tbs" {
  description = "Storage in TB. Minimum 1."
  type        = number
  default     = 1
}

variable "auto_scaling_enabled" {
  description = "Let the database scale compute up to 3x the base count on demand."
  type        = bool
  default     = false
}

variable "auto_scaling_for_storage_enabled" {
  description = "Let storage grow beyond the reserved size on demand."
  type        = bool
  default     = false
}

variable "backup_retention_period_in_days" {
  description = "Automatic backup retention, 1-60 days."
  type        = number
  default     = 60
}

variable "character_set" {
  type    = string
  default = "AL32UTF8"
}

variable "national_character_set" {
  type    = string
  default = "AL16UTF16"
}

# No default: the password must never be written into a generated file. Supply
# it at apply time from the root's autonomous_db_admin_passwords map, or from a
# secret store. 12-30 chars, upper + lower + digit, no double quote, cannot
# contain the word "admin".
variable "admin_password" {
  description = "ADMIN user password."
  type        = string
  sensitive   = true
}

variable "mtls_connection_required" {
  description = "Require mutual TLS. Set false to allow TLS-only connections."
  type        = bool
  default     = true
}

# ── Network ───────────────────────────────────────────────────────────────────
# Wired in the root from the VNet module's delegated subnet.
variable "subnet_id" {
  description = "Oracle-delegated subnet ID — wired from module.vnet in root. Empty means public access."
  type        = string
  default     = ""
}

variable "virtual_network_id" {
  description = "VNet ID holding the delegated subnet — wired from module.vnet in root. Empty means public access."
  type        = string
  default     = ""
}

variable "allowed_ips" {
  description = "Public access control list. Leave empty when using a delegated subnet."
  type        = list(string)
  default     = []
}

variable "customer_contacts" {
  description = "Email addresses Oracle notifies about this database."
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
