# Variable definitions. Real values go in terraform.tfvars.

variable "gcp_project" {
  description = "Default GCP project ID. Override per-resource via the project field in a map entry."
  type        = string
}

variable "gcp_region" {
  description = "Default GCP region. Override per-resource via the location field in a map entry."
  type        = string
}

# ── ODB Networks ──────────────────────────────────────────────────────────────
variable "gcp_odb_networks" {
  description = "Map of ODB Networks. Key is referenced by gcp_vm_clusters.network_key."
  type = map(object({
    odb_network_id      = string
    network             = string
    client_subnet_id    = string
    client_cidr_range   = string
    backup_subnet_id    = string
    backup_cidr_range   = string
    location            = optional(string, "")
    project             = optional(string, "")
    gcp_oracle_zone     = optional(string, "")
    deletion_protection = optional(bool, true)
    labels              = optional(map(string), {})
  }))
  default = {}
}

# ── Exadata Infrastructures ───────────────────────────────────────────────────
variable "gcp_exadata_infras" {
  description = "Map of Exadata Infrastructures. Key is referenced by gcp_vm_clusters.infra_key."
  type = map(object({
    cloud_exadata_infrastructure_id     = string
    shape                               = string
    compute_count                       = number
    storage_count                       = number
    location                            = optional(string, "")
    display_name                        = optional(string, "")
    gcp_oracle_zone                     = optional(string, "")
    project                             = optional(string, "")
    total_storage_size_gb               = optional(number, 0)
    customer_contacts                   = optional(list(string), [])
    mw_preference                       = optional(string, "NO_PREFERENCE")
    mw_patching_mode                    = optional(string, "ROLLING")
    mw_is_custom_action_timeout_enabled = optional(bool, false)
    mw_custom_action_timeout_mins       = optional(number, 15)
    mw_lead_time_week                   = optional(number, null)
    mw_days_of_week                     = optional(list(string), [])
    mw_months                           = optional(list(string), [])
    mw_hours_of_day                     = optional(list(number), [])
    mw_weeks_of_month                   = optional(list(number), [])
    deletion_protection                 = optional(bool, true)
    labels                              = optional(map(string), {})
  }))
  default = {}
}

# ── ExaDB VM Clusters ─────────────────────────────────────────────────────────
variable "gcp_vm_clusters" {
  description = "Map of ExaDB VM Clusters. infra_key and network_key must match keys in gcp_exadata_infras and gcp_odb_networks."
  type = map(object({
    infra_key                = string
    network_key              = string
    cloud_vm_cluster_id      = string
    hostname_prefix          = string
    cpu_core_count           = number
    memory_size_gb           = number
    db_node_storage_size_gb  = number
    data_storage_size_tb     = number
    ssh_public_keys          = list(string)
    display_name             = optional(string, "")
    location                 = optional(string, "")
    project                  = optional(string, "")
    gi_version               = optional(string, "23.0.0.0")
    license_type             = optional(string, "LICENSE_INCLUDED")
    local_backup_enabled     = optional(bool, false)
    sparse_diskgroup_enabled = optional(bool, false)
    cluster_name             = optional(string, null)
    node_count               = optional(number, null)
    ocpu_count               = optional(number, null)
    disk_redundancy          = optional(string, null)
    time_zone                = optional(string, "UTC")
    scan_listener_port_tcp   = optional(number, null)
    dco_diagnostics          = optional(bool, true)
    dco_health               = optional(bool, true)
    dco_incident_logs        = optional(bool, true)
    deletion_protection      = optional(bool, true)
    labels                   = optional(map(string), {})
  }))
  default = {}
}

# ── ODB Networks — Autonomous AI Database Serverless only ─────────────────────
# Same as gcp_odb_networks minus the backup subnet, which only Exadata VM
# Clusters use. Keys here share one namespace with gcp_odb_networks: a key in
# both maps is rejected before apply.
variable "gcp_odb_networks_adbs" {
  description = "Map of ODB Networks with a client subnet only. Key is referenced by gcp_autonomous_dbs.network_key. Not usable by gcp_vm_clusters."
  type = map(object({
    odb_network_id    = string
    network           = string
    client_subnet_id  = string
    client_cidr_range = string
    # No backup_subnet_id / backup_cidr_range — an Autonomous Database never
    # uses a backup subnet. Use gcp_odb_networks if a VM Cluster needs one too.
    location            = optional(string, "")
    project             = optional(string, "")
    gcp_oracle_zone     = optional(string, "")
    deletion_protection = optional(bool, true)
    labels              = optional(map(string), {})
  }))
  default = {}
}

# ── Autonomous AI Databases (Serverless) ──────────────────────────────────────
# Independent of gcp_exadata_infras and gcp_vm_clusters: Oracle runs the fleet,
# so there is no Exadata Infrastructure or VM Cluster underneath and no
# infra_key. Leave the map empty and nothing is created.
#
# Regional, not zonal — unlike infrastructures, clusters and subnets, an
# Autonomous Database takes no gcp_oracle_zone.
variable "gcp_autonomous_dbs" {
  description = "Map of Autonomous AI Databases (Serverless). network_key must match a key in gcp_odb_networks or gcp_odb_networks_adbs."
  type = map(object({
    autonomous_database_id = string # immutable; lowercase letters/digits/hyphens, max 63
    database               = string # Oracle DB name: starts with a letter, max 30 alphanumeric
    network_key            = string # key in gcp_odb_networks or gcp_odb_networks_adbs

    display_name = optional(string, "") # falls back to autonomous_database_id
    location     = optional(string, "") # region override (defaults to gcp_region)
    project      = optional(string, "") # project override (defaults to gcp_project)

    db_workload  = optional(string, "OLTP")               # OLTP | DW | AJD | APEX
    license_type = optional(string, "LICENSE_INCLUDED")   # or BRING_YOUR_OWN_LICENSE
    db_edition   = optional(string, "ENTERPRISE_EDITION") # or STANDARD_EDITION
    db_version   = optional(string, "23ai")               # 19c | 23ai

    compute_count                   = optional(number, 2)   # ECPUs, minimum 2
    data_storage_size_gb            = optional(number, 120) # storage in GB
    is_auto_scaling_enabled         = optional(bool, true)  # compute up to 3x on demand
    is_storage_auto_scaling_enabled = optional(bool, false)

    backup_retention_period_days = optional(number, 60)        # 1-60
    maintenance_schedule_type    = optional(string, "REGULAR") # EARLY patches a week ahead

    character_set             = optional(string, "AL32UTF8")
    n_character_set           = optional(string, "AL16UTF16")
    operations_insights_state = optional(string, "NOT_ENABLED") # or ENABLED

    mtls_connection_required = optional(bool, true)
    # Hostname prefix and IP for the private endpoint. Empty means Oracle picks
    # one; an IP given here must sit inside the client subnet's CIDR.
    private_endpoint_label = optional(string, "")
    private_endpoint_ip    = optional(string, "")

    customer_contacts   = optional(list(string), [])
    deletion_protection = optional(bool, true)
    labels              = optional(map(string), {})
  }))
  default = {}
}

# Never put these in terraform.tfvars. Supply them at apply time, keyed by the
# same key used in gcp_autonomous_dbs:
#
#   export TF_VAR_gcp_adb_admin_passwords='{"adb1":"..."}'
#
# Oracle's rules: 12-30 chars, at least one upper, one lower and one digit, no
# double quote, and it cannot contain the word "admin".
variable "gcp_adb_admin_passwords" {
  description = "ADMIN passwords for each entry in gcp_autonomous_dbs, keyed by the same map key."
  type        = map(string)
  sensitive   = true
  default     = {}
}
