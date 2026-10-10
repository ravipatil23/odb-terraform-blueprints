# Variable definitions. Real values go in terraform.tfvars — you normally do
# not need to touch this file.

variable "aws_region" {
  description = "Default AWS region for the ODB deployment."
  type        = string
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}

# ── Existing (externally provisioned) resources ───────────────────────────────
# Point the blueprint at an ODB Network or Exadata Infrastructure that already
# exists — provisioned by hand, by another stack, or by a different team. An
# entry here is referenced by ID and never created, updated or destroyed.
#
# Key these maps exactly the way aws_clusters / aws_peerings already reference
# them (network_ref / infra_ref), and leave the matching aws_networks /
# aws_infras entry out. Managed and existing resources share one keyspace, so
# you can mix both in a single configuration.

variable "existing_odb_network_ids" {
  description = "IDs of ODB Networks that already exist, keyed by the name used in aws_clusters.network_ref / aws_peerings.network_ref."
  type        = map(string)
  default     = {}
}

variable "existing_infra_ids" {
  description = "IDs of Exadata Infrastructures that already exist, keyed by the name used in aws_clusters.infra_ref."
  type        = map(string)
  default     = {}
}

# ── ODB Networks ──────────────────────────────────────────────────────────────
variable "aws_networks" {
  description = "Map of ODB Networks, keyed by a short name you choose. The key is referenced by aws_clusters.network_ref and aws_peerings.network_ref."
  type = map(object({
    display_name                = string
    availability_zone_id        = string
    client_subnet_cidr          = string
    backup_subnet_cidr          = string
    s3_access                   = optional(string, "ENABLED")
    zero_etl_access             = optional(string, "DISABLED")
    availability_zone           = optional(string, "")
    region                      = optional(string, "")
    custom_domain_name          = optional(string, "")
    default_dns_prefix          = optional(string, "")
    delete_associated_resources = optional(bool, false)

    # Separate runs on purpose: terraform fmt aligns arguments between blank
    # lines, so keeping the long key below apart leaves the block above at its
    # own width instead of padding every line to 38 characters.
    #
    # sts_access and kms_access are Optional + Computed in the provider. Leaving
    # one empty accepts whatever the service assigned and produces no drift.
    sts_access          = optional(string, "")
    kms_access          = optional(string, "")
    s3_policy_document  = optional(string, "")
    sts_policy_document = optional(string, "")
    kms_policy_document = optional(string, "")

    cross_region_s3_restore_sources_access = optional(set(string), [])
  }))
  default = {}
}

# ── Exadata Infrastructures ───────────────────────────────────────────────────
variable "aws_infras" {
  description = "Map of Exadata Infrastructures, keyed by a short name. The key is referenced by aws_clusters.infra_ref."
  type = map(object({
    display_name                        = string
    availability_zone_id                = string
    shape                               = optional(string, "Exadata.X11M")
    compute_count                       = optional(number, 2)
    storage_count                       = optional(number, 3)
    availability_zone                   = optional(string, "")
    region                              = optional(string, "")
    database_server_type                = optional(string, "")
    storage_server_type                 = optional(string, "")
    customer_contacts                   = optional(list(string), [])
    mw_preference                       = optional(string, "NO_PREFERENCE")
    mw_patching_mode                    = optional(string, "ROLLING")
    mw_is_custom_action_timeout_enabled = optional(bool, false)
    mw_custom_action_timeout_in_mins    = optional(number, 15)
    mw_lead_time_in_weeks               = optional(number, 0)
    mw_days_of_week                     = optional(list(string), [])
    mw_months                           = optional(list(string), [])
    mw_hours_of_day                     = optional(list(number), [])
    mw_weeks_of_month                   = optional(list(number), [])
  }))
  default = {}
}

# ── Network Peerings (optional) ───────────────────────────────────────────────
variable "aws_peerings" {
  description = "Map of ODB Network Peering Connections. network_ref must match a key in aws_networks."
  type = map(object({
    display_name    = string
    network_ref     = string
    peer_network_id = string
    region          = optional(string, "")
  }))
  default = {}
}

# ── VM Clusters ───────────────────────────────────────────────────────────────
variable "aws_clusters" {
  description = "Map of VM Clusters. infra_ref and network_ref must match keys in aws_infras and aws_networks."
  type = map(object({
    display_name                      = string
    gi_version                        = string
    hostname_prefix                   = string
    infra_ref                         = string
    network_ref                       = string
    cpu_core_count                    = optional(number, 16)
    license_model                     = optional(string, "LICENSE_INCLUDED")
    ssh_public_keys                   = optional(list(string), [])
    db_servers                        = optional(list(string), [])
    db_servers_mode                   = optional(string, "auto") # "auto" = discover from infra, "manual" = use db_servers
    dco_is_diagnostics_events_enabled = optional(bool, true)
    dco_is_health_monitoring_enabled  = optional(bool, true)
    dco_is_incident_logs_enabled      = optional(bool, true)
    cluster_name                      = optional(string, "")
    timezone                          = optional(string, "")
    data_storage_size_in_tbs          = optional(number, null)
    db_node_storage_size_in_gbs       = optional(number, null)
    memory_size_in_gbs                = optional(number, null)
    scan_listener_port_tcp            = optional(number, null)
    is_local_backup_enabled           = optional(bool, false)
    is_sparse_diskgroup_enabled       = optional(bool, false)
  }))
  default = {}

  # db_servers_mode is read by this blueprint, not by the AWS provider - the
  # provider only ever sees the resulting db_servers list. So a typo is not
  # caught by the API: anything other than "auto" silently takes the manual
  # branch, and since db_servers defaults to [] the cluster is created with the
  # service choosing its own servers. That looks exactly like auto-discovery
  # having worked. Reject the typo here instead.
  validation {
    condition = alltrue([
      for k, c in var.aws_clusters : contains(["auto", "manual"], c.db_servers_mode)
    ])
    error_message = "db_servers_mode must be exactly \"auto\" or \"manual\". \"auto\" discovers DB servers from the infrastructure; \"manual\" uses the db_servers list you supply."
  }

  # "manual" with no servers listed is the same silent outcome by a different
  # route - the mode says you are choosing, but nothing was chosen.
  validation {
    condition = alltrue([
      for k, c in var.aws_clusters :
      c.db_servers_mode != "manual" || length(c.db_servers) > 0
    ])
    error_message = "A cluster with db_servers_mode = \"manual\" must list at least one entry in db_servers. Use \"auto\" to discover them from the infrastructure instead."
  }
}

# ── Autonomous VM Clusters (ADB-D, optional) ──────────────────────────────────
# The Autonomous counterpart of aws_clusters. Both sit on the same Exadata
# infrastructure and ODB network - infra_ref / network_ref key into the same
# maps - but they host different things:
#
#   aws_clusters             -> DB Homes / CDBs / PDBs   (see ../oci-database)
#   aws_autonomous_clusters  -> Autonomous Container Databases / Autonomous DBs
#
# Sizing is per node and per Oracle Compute Unit rather than cluster totals,
# which is why this is a separate map rather than fields on aws_clusters.
#
# Leave it empty and nothing here applies.
variable "aws_autonomous_clusters" {
  description = "Map of Autonomous VM Clusters (ADB-D). infra_ref and network_ref must match keys in aws_infras / aws_networks."
  type = map(object({
    display_name = string
    infra_ref    = string
    network_ref  = string

    # Required by the API. The provider schema marks nothing required, so a
    # missing value would otherwise surface as an apply-time error.
    autonomous_data_storage_size_in_tbs   = number
    cpu_core_count_per_node               = number
    memory_per_oracle_compute_unit_in_gbs = number
    total_container_databases             = number

    scan_listener_port_tls     = optional(number, 2484)
    scan_listener_port_non_tls = optional(number, 1521)

    license_model              = optional(string, "LICENSE_INCLUDED")
    is_mtls_enabled_vm_cluster = optional(bool, false)
    time_zone                  = optional(string, "")
    description                = optional(string, "")

    db_servers      = optional(list(string), [])
    db_servers_mode = optional(string, "auto") # "auto" = discover from infra, "manual" = use db_servers

    # Maintenance window — required on the cluster here, unlike ExaDB-D where it
    # lives on the infrastructure. No patching_mode or custom action timeout.
    mw_preference         = optional(string, "NO_PREFERENCE")
    mw_lead_time_in_weeks = optional(number, 0)
    mw_days_of_week       = optional(list(string), [])
    mw_months             = optional(list(string), [])
    mw_hours_of_day       = optional(list(number), [])
    mw_weeks_of_month     = optional(list(number), [])
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, c in var.aws_autonomous_clusters : contains(["auto", "manual"], c.db_servers_mode)
    ])
    error_message = "db_servers_mode must be exactly \"auto\" or \"manual\"."
  }

  validation {
    condition = alltrue([
      for k, c in var.aws_autonomous_clusters :
      c.db_servers_mode != "manual" || length(c.db_servers) > 0
    ])
    error_message = "An Autonomous cluster with db_servers_mode = \"manual\" must list at least one entry in db_servers."
  }
}
