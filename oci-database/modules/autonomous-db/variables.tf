variable "autonomous_container_database_id" {
  description = "OCID of the parent Autonomous Container Database (wired from the autonomous-container-db module in root)."
  type        = string
}

variable "compartment_id" {
  description = "Compartment OCID. Required by the provider for this resource — unlike the container, it is not inherited."
  type        = string
}

variable "db_name" {
  description = "Database name — max 30 alphanumeric chars, unique among the tenancy's Autonomous Databases."
  type        = string
}

variable "display_name" {
  description = "Friendly name. Blank falls back to db_name."
  type        = string
  default     = ""
}

# ── Admin password: supply exactly one of these two routes ────────────────────
variable "admin_password_secret_id" {
  description = "OCID of an OCI Vault secret holding the ADMIN password. Preferred: the resource stores a reference, so the password never enters Terraform state. Mutually exclusive with admin_password."
  type        = string
  default     = ""
}

variable "admin_password_secret_version_number" {
  description = "Version of the Vault secret to read. null takes the current version, so a later rotation is picked up without a config change."
  type        = number
  default     = null
}

variable "admin_password" {
  description = "Literal ADMIN password. Lands in Terraform state in cleartext — prefer admin_password_secret_id. Supply via TF_VAR_*, never in tfvars."
  type        = string
  default     = ""
  sensitive   = true
}

# ── Sizing ───────────────────────────────────────────────────────────────────
variable "compute_model" {
  description = "ECPU or OCPU. ECPU is the current model and pairs with compute_count."
  type        = string
  default     = "ECPU"
  validation {
    condition     = contains(["ECPU", "OCPU", ""], var.compute_model)
    error_message = "Must be ECPU, OCPU, or empty to accept the service default."
  }
}

variable "compute_count" {
  description = "ECPU count, fractional allowed. Use with compute_model ECPU and leave cpu_core_count null."
  type        = number
  default     = null
}

variable "cpu_core_count" {
  description = "OCPU count. Only for compute_model OCPU; leave compute_count null."
  type        = number
  default     = null
}

variable "data_storage_size_in_tbs" {
  description = "Storage in TB. null accepts the service default."
  type        = number
  default     = null
}

variable "is_auto_scaling_enabled" {
  description = "Allow compute auto-scaling up to 3x. null accepts the service default."
  type        = bool
  default     = null
}

variable "is_auto_scaling_for_storage_enabled" {
  description = "Allow storage auto-scaling. null accepts the service default."
  type        = bool
  default     = null
}

# ── Shape and behaviour ──────────────────────────────────────────────────────
variable "db_workload" {
  description = "OLTP or DW. AJD and APEX are Serverless-only shapes."
  type        = string
  default     = "OLTP"
  validation {
    condition     = contains(["OLTP", "DW", ""], var.db_workload)
    error_message = "Must be OLTP, DW, or empty to accept the service default."
  }
}

variable "db_version" {
  description = "Oracle version, e.g. 19c or 23ai. Blank takes the container's. Drift is ignored — Oracle patches it."
  type        = string
  default     = ""
}

variable "database_edition" {
  description = "STANDARD_EDITION or ENTERPRISE_EDITION. Blank accepts the service default."
  type        = string
  default     = ""
}

variable "license_model" {
  description = "LICENSE_INCLUDED or BRING_YOUR_OWN_LICENSE. On ADB-D licensing is normally set on the Autonomous VM Cluster — leave blank unless this database differs."
  type        = string
  default     = ""
  validation {
    condition     = contains(["LICENSE_INCLUDED", "BRING_YOUR_OWN_LICENSE", ""], var.license_model)
    error_message = "Must be LICENSE_INCLUDED, BRING_YOUR_OWN_LICENSE, or empty."
  }
}

variable "character_set" {
  description = "Database character set. Blank accepts the default, AL32UTF8."
  type        = string
  default     = ""
}

variable "ncharacter_set" {
  description = "National character set. Blank accepts the default, AL16UTF16."
  type        = string
  default     = ""
}

variable "in_memory_percentage" {
  description = "Percentage of memory given to the In-Memory column store. null accepts the service default."
  type        = number
  default     = null
}

variable "is_mtls_connection_required" {
  description = "Require mutual TLS. null accepts the service default."
  type        = bool
  default     = null
}

variable "autonomous_maintenance_schedule_type" {
  description = "EARLY or REGULAR patch schedule."
  type        = string
  default     = ""
  validation {
    condition     = contains(["EARLY", "REGULAR", ""], var.autonomous_maintenance_schedule_type)
    error_message = "Must be EARLY, REGULAR, or empty."
  }
}

variable "kms_key_id" {
  description = "Customer-managed TDE key OCID for this database. Requires vault_id."
  type        = string
  default     = ""
}

variable "vault_id" {
  description = "OCI Vault OCID holding kms_key_id."
  type        = string
  default     = ""
}

variable "customer_contacts" {
  description = "Email addresses notified about this database."
  type        = list(string)
  default     = []
}

variable "freeform_tags" {
  description = "Freeform tags."
  type        = map(string)
  default     = {}
}

variable "defined_tags" {
  description = "Defined tags, as namespace.key => value."
  type        = map(string)
  default     = {}
}
