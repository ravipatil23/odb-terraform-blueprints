variable "oci_region" {
  type        = string
  description = "OCI region, e.g. \"us-ashburn-1\"."
}

variable "container_database_id" {
  type        = string
  description = "OCID of the existing CDB this PDB is created in (ocid1.database...). Output of the cdb template."
}

variable "pdb_name" {
  type        = string
  description = "PDB name. Max 30 characters, and must differ from the CDB name."

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_]{0,29}$", var.pdb_name))
    error_message = "pdb_name must start with a letter and be 1-30 characters of letters, digits or underscores."
  }
}

variable "pdb_admin_password" {
  type        = string
  sensitive   = true
  description = "PDB admin password. Supply via TF_VAR_pdb_admin_password, not tfvars. Oracle rules: 9-30 chars, at least 2 uppercase, 2 lowercase, 2 digits and 2 special characters."
}

variable "tde_wallet_password" {
  type        = string
  sensitive   = true
  default     = ""
  description = "TDE wallet password. Defaults to pdb_admin_password when empty."
}
