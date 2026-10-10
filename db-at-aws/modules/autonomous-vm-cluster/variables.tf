variable "display_name" {
  type        = string
  description = "Display name for the Autonomous VM cluster."
}

variable "cloud_exadata_infrastructure_id" {
  type        = string
  description = "ID of the Exadata infrastructure this cluster runs on."
}

variable "odb_network_id" {
  type        = string
  description = "ID of the ODB network this cluster attaches to."
}

variable "db_servers" {
  type        = list(string)
  default     = []
  description = "DB server IDs backing the cluster. Wired from the root: discovered via data.aws_odb_db_servers when db_servers_mode = \"auto\", or the list you supplied when \"manual\"."
}

# ── Sizing ───────────────────────────────────────────────────────────────────
# Expressed per node and per Oracle Compute Unit, not as cluster totals. The
# API requires all four; nothing in the provider schema enforces that, so these
# have no defaults - a missing one should fail here, not hours into an apply.

variable "autonomous_data_storage_size_in_tbs" {
  type        = number
  description = "Data storage allocated for Autonomous Databases, in TB."
}

variable "cpu_core_count_per_node" {
  type        = number
  description = "CPU cores enabled on each node."
}

variable "memory_per_oracle_compute_unit_in_gbs" {
  type        = number
  description = "Memory per Oracle Compute Unit, in GB."
}

variable "total_container_databases" {
  type        = number
  description = "Maximum number of Autonomous Container Databases the cluster can host."
}

# ── Listeners ────────────────────────────────────────────────────────────────

variable "scan_listener_port_tls" {
  type        = number
  default     = 2484
  description = "SCAN listener port for TLS connections."
}

variable "scan_listener_port_non_tls" {
  type        = number
  default     = 1521
  description = "SCAN listener port for non-TLS connections."
}

# ── Options ──────────────────────────────────────────────────────────────────

variable "license_model" {
  type    = string
  default = "LICENSE_INCLUDED"
  validation {
    condition     = contains(["LICENSE_INCLUDED", "BRING_YOUR_OWN_LICENSE"], var.license_model)
    error_message = "Must be LICENSE_INCLUDED or BRING_YOUR_OWN_LICENSE."
  }
}

variable "is_mtls_enabled_vm_cluster" {
  type        = bool
  default     = false
  description = "Require mutual TLS for connections to this cluster."
}

variable "time_zone" {
  type        = string
  default     = ""
  description = "Cluster time zone, e.g. \"UTC\". Empty leaves the service default."
}

variable "description" {
  type        = string
  default     = ""
  description = "Free-text description of the cluster."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to the cluster."
}

# ── Maintenance window ───────────────────────────────────────────────────────
# Required by the API. Note this differs from ExaDB-D, where the window lives on
# the Exadata infrastructure instead - and this one has no patching_mode or
# custom action timeout.

variable "mw_preference" {
  type        = string
  default     = "NO_PREFERENCE"
  description = "Maintenance window preference. NO_PREFERENCE lets Oracle choose; CUSTOM_PREFERENCE uses the fields below."
  validation {
    condition     = contains(["NO_PREFERENCE", "CUSTOM_PREFERENCE"], var.mw_preference)
    error_message = "Must be NO_PREFERENCE or CUSTOM_PREFERENCE."
  }
}

variable "mw_lead_time_in_weeks" {
  type        = number
  default     = 0
  description = "Lead time in weeks before a maintenance run. 0 leaves it unset."
}

variable "mw_days_of_week" {
  type        = list(string)
  default     = []
  description = "Days the window may run, e.g. [\"MONDAY\", \"TUESDAY\"]. Only meaningful with CUSTOM_PREFERENCE."
  validation {
    condition = alltrue([
      for d in var.mw_days_of_week :
      contains(["MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY"], d)
    ])
    error_message = "Days must be uppercase English day names, e.g. MONDAY."
  }
}

variable "mw_months" {
  type        = list(string)
  default     = []
  description = "Months the window may run, e.g. [\"FEBRUARY\", \"MAY\"]. Only meaningful with CUSTOM_PREFERENCE."
  validation {
    condition = alltrue([
      for m in var.mw_months :
      contains([
        "JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE",
        "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER"
      ], m)
    ])
    error_message = "Months must be uppercase English month names, e.g. FEBRUARY."
  }
}

variable "mw_hours_of_day" {
  type        = list(number)
  default     = []
  description = "Hours (0-23, UTC) the window may start."
  validation {
    condition     = alltrue([for h in var.mw_hours_of_day : h >= 0 && h <= 23])
    error_message = "Hours must be between 0 and 23."
  }
}

variable "mw_weeks_of_month" {
  type        = list(number)
  default     = []
  description = "Weeks of the month (1-4) the window may run."
  validation {
    condition     = alltrue([for w in var.mw_weeks_of_month : w >= 1 && w <= 4])
    error_message = "Weeks of month must be between 1 and 4."
  }
}
