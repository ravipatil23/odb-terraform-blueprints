variable "cloud_autonomous_vm_cluster_ocid" {
  description = "OCID of the Autonomous VM Cluster to create the container on. On Database@AWS this is the `ocid` output of db-at-aws's autonomous-vm-cluster module."
  type        = string
}

variable "display_name" {
  description = "Display name for the Autonomous Container Database."
  type        = string
}

variable "patch_model" {
  description = "Patch stream: RELEASE_UPDATES or RELEASE_UPDATE_REVISIONS."
  type        = string
  default     = "RELEASE_UPDATES"
  validation {
    condition     = contains(["RELEASE_UPDATES", "RELEASE_UPDATE_REVISIONS"], var.patch_model)
    error_message = "Must be RELEASE_UPDATES or RELEASE_UPDATE_REVISIONS."
  }
}

variable "compartment_id" {
  description = "Compartment OCID. Blank inherits the Autonomous VM Cluster's compartment."
  type        = string
  default     = ""
}

variable "db_name" {
  description = "Container database name (max 8 alphanumeric chars). Blank lets the service generate one."
  type        = string
  default     = ""
}

variable "db_unique_name" {
  description = "Optional DB unique name."
  type        = string
  default     = ""
}

variable "db_version" {
  description = "Oracle Database version for the container, e.g. 19.0.0.0. Blank takes the cluster default. Drift on this field is ignored — Oracle patches the container itself."
  type        = string
  default     = ""
}

variable "service_level_agreement_type" {
  description = "STANDARD or AUTONOMOUS_DATAGUARD. AUTONOMOUS_DATAGUARD additionally needs a peer, which this module does not wire."
  type        = string
  default     = ""
  validation {
    condition     = contains(["STANDARD", "AUTONOMOUS_DATAGUARD", ""], var.service_level_agreement_type)
    error_message = "Must be STANDARD, AUTONOMOUS_DATAGUARD, or empty to accept the service default."
  }
}

variable "distribution_affinity" {
  description = "MINIMUM_DISTRIBUTION or MAXIMUM_DISTRIBUTION — how the container's databases spread across the cluster's VMs."
  type        = string
  default     = ""
  validation {
    condition     = contains(["MINIMUM_DISTRIBUTION", "MAXIMUM_DISTRIBUTION", ""], var.distribution_affinity)
    error_message = "Must be MINIMUM_DISTRIBUTION, MAXIMUM_DISTRIBUTION, or empty."
  }
}

variable "net_services_architecture" {
  description = "DEDICATED or SHARED listener architecture."
  type        = string
  default     = ""
  validation {
    condition     = contains(["DEDICATED", "SHARED", ""], var.net_services_architecture)
    error_message = "Must be DEDICATED, SHARED, or empty."
  }
}

variable "version_preference" {
  description = "NEXT_RELEASE_UPDATE or LATEST_RELEASE_UPDATE."
  type        = string
  default     = ""
  validation {
    condition     = contains(["NEXT_RELEASE_UPDATE", "LATEST_RELEASE_UPDATE", ""], var.version_preference)
    error_message = "Must be NEXT_RELEASE_UPDATE, LATEST_RELEASE_UPDATE, or empty."
  }
}

variable "db_split_threshold" {
  description = "CPU threshold at which a database is split across nodes. null accepts the service default."
  type        = number
  default     = null
}

variable "vm_failover_reservation" {
  description = "Percentage of cluster capacity held in reserve for VM failover. 0 reserves nothing; null accepts the service default."
  type        = number
  default     = null
}

variable "is_dst_file_update_enabled" {
  description = "Apply DST timezone file updates during maintenance. null accepts the service default."
  type        = bool
  default     = null
}

variable "kms_key_id" {
  description = "Customer-managed TDE key OCID. Requires vault_id. Blank uses Oracle-managed keys."
  type        = string
  default     = ""
}

variable "vault_id" {
  description = "OCI Vault OCID holding kms_key_id."
  type        = string
  default     = ""
}

variable "backup_recovery_window_in_days" {
  description = "Backup retention for the container, in days. null keeps the service default."
  type        = number
  default     = null
}

variable "customer_contacts" {
  description = "Email addresses notified about maintenance and events."
  type        = list(string)
  default     = []
}

variable "maintenance_window" {
  description = "Patching window. null accepts the service default (NO_PREFERENCE)."
  type = object({
    preference                       = optional(string, "")
    patching_mode                    = optional(string, "")
    is_monthly_patching_enabled      = optional(bool, null)
    lead_time_in_weeks               = optional(number, null)
    hours_of_day                     = optional(list(number), [])
    days_of_week                     = optional(list(string), [])
    months                           = optional(list(string), [])
    weeks_of_month                   = optional(list(number), [])
    custom_action_timeout_in_mins    = optional(number, null)
    is_custom_action_timeout_enabled = optional(bool, null)
  })
  default = null
}

variable "freeform_tags" {
  description = "Freeform tags."
  type        = map(string)
  default     = {}
}

variable "defined_tags" {
  description = "Defined tags, as \"namespace.key\" => value."
  type        = map(string)
  default     = {}
}
