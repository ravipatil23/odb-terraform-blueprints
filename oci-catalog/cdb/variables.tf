variable "oci_region" {
  type        = string
  description = "OCI region, e.g. \"us-ashburn-1\"."
}

variable "db_home_id" {
  type        = string
  description = "OCID of the existing DB Home this CDB is created in (ocid1.dbhome...). Output of the db-home template."
}

variable "db_name" {
  type        = string
  description = "CDB name. Max 8 alphanumeric characters, no special characters."

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9]{0,7}$", var.db_name))
    error_message = "db_name must start with a letter and be 1-8 alphanumeric characters."
  }
}

variable "admin_password" {
  type        = string
  sensitive   = true
  description = "SYS password. Supply via TF_VAR_admin_password, not tfvars. Oracle rules: 9-30 chars, at least 2 uppercase, 2 lowercase, 2 digits and 2 special characters, and not the DB name."
}

variable "character_set" {
  type        = string
  default     = "AL32UTF8"
  description = "Database character set."
}

variable "ncharacter_set" {
  type        = string
  default     = "AL16UTF16"
  description = "National character set."
}

variable "initial_pdb_name" {
  type        = string
  default     = ""
  description = "Create this PDB alongside the CDB. Leave empty and use the pdb template instead — that keeps PDBs independently manageable."
}

variable "db_unique_name" {
  type        = string
  default     = ""
  description = "DB unique name. Defaults to a generated one when empty."
}

variable "sid_prefix" {
  type        = string
  default     = ""
  description = "SID prefix. Defaults to the db_name when empty."
}

variable "auto_backup_enabled" {
  type        = bool
  default     = false
  description = "Enable managed automatic backups."
}

variable "auto_backup_window" {
  type        = string
  default     = "SLOT_TWO"
  description = "Backup window slot. Only applied when auto_backup_enabled is true."
}

variable "recovery_window_in_days" {
  type        = number
  default     = 30
  description = "Backup retention in days. Only applied when auto_backup_enabled is true."
}
