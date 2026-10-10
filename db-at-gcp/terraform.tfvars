# ─────────────────────────────────────────────────────────────────────────────
# Oracle Database@GCP — fill in your values here. This is the ONLY file you
# normally need to edit. Add more entries to any map to create more resources.
#
# Commented lines show OPTIONAL parameters with their default/sample values —
# uncomment and edit any you need. Uncommented lines are required (or recommended).
# ─────────────────────────────────────────────────────────────────────────────

gcp_project = "my-gcp-project"
gcp_region  = "us-east4"

# ── ODB Networks (creates the network + client & backup subnets) ──────────────
# Key ("net1") is referenced by gcp_vm_clusters.network_key below.
gcp_odb_networks = {
  net1 = {
    odb_network_id    = "odbnet-prod"
    network           = "projects/my-gcp-project/global/networks/default"
    client_subnet_id  = "odb-client-prod"
    client_cidr_range = "10.30.0.0/24"
    backup_subnet_id  = "odb-backup-prod"
    backup_cidr_range = "10.30.1.0/24"

    # ── optional (defaults shown) ──
    # location            = ""                # region override (defaults to gcp_region)
    # project             = ""                # project override (defaults to gcp_project)
    # gcp_oracle_zone     = "us-east4-b-r1"   # Oracle zone within the region
    # deletion_protection = true
    # labels              = { env = "prod" }
  }
}

# ── Exadata Infrastructures ───────────────────────────────────────────────────
gcp_exadata_infras = {
  infra1 = {
    cloud_exadata_infrastructure_id = "exa-prod"
    shape                           = "Exadata.X11M"
    compute_count                   = 2
    storage_count                   = 3

    # ── optional (defaults shown) ──
    # display_name                        = "Exadata Prod"
    # gcp_oracle_zone                     = "us-east4-b-r1"
    # location                            = ""               # region override
    # project                             = ""               # project override
    # total_storage_size_gb               = 0                # 0 = shape default
    # customer_contacts                   = ["dba@example.com"]
    # mw_preference                       = "NO_PREFERENCE"  # NO_PREFERENCE | CUSTOM_PREFERENCE
    # mw_patching_mode                    = "ROLLING"        # ROLLING | NONROLLING
    # mw_is_custom_action_timeout_enabled = false
    # mw_custom_action_timeout_mins       = 15
    # mw_lead_time_week                   = 1
    # mw_days_of_week                     = ["MONDAY"]
    # mw_months                           = ["JANUARY"]
    # mw_hours_of_day                     = [4]              # 0,4,8,12,16,20 UTC
    # mw_weeks_of_month                   = [1]              # 1-4
    # deletion_protection                 = true
    # labels                              = { env = "prod" }
  }
}

# ── ExaDB VM Clusters ─────────────────────────────────────────────────────────
# infra_key / network_key must match keys above.
gcp_vm_clusters = {
  vmc1 = {
    infra_key               = "infra1"
    network_key             = "net1"
    cloud_vm_cluster_id     = "vmc-prod"
    hostname_prefix         = "exadb"
    cpu_core_count          = 4
    memory_size_gb          = 60
    db_node_storage_size_gb = 120
    data_storage_size_tb    = 2
    ssh_public_keys = [
      "ssh-rsa AAAAB3Nza... replace-with-your-key",
    ]

    # ── optional (defaults shown) ──
    # display_name             = "VM Cluster Prod"
    # location                 = ""               # region override
    # project                  = ""               # project override
    # gi_version               = "23.0.0.0"
    # license_type             = "LICENSE_INCLUDED"  # or BRING_YOUR_OWN_LICENSE
    # local_backup_enabled     = false
    # sparse_diskgroup_enabled = false
    # cluster_name             = "prodclu"        # max 11 chars
    # node_count               = 2
    # ocpu_count               = 4                # fractional OCPU allocation
    # disk_redundancy          = "HIGH"           # HIGH | NORMAL
    # time_zone                = "UTC"
    # scan_listener_port_tcp   = 1521
    # dco_diagnostics          = true
    # dco_health               = true
    # dco_incident_logs        = true
    # deletion_protection      = true
    # labels                   = { env = "prod" }
  }
}

# ── ODB Networks — Autonomous AI Database Serverless only (optional) ──────────
# Same as gcp_odb_networks above, minus the backup subnet: an Autonomous
# Database never uses one. A VM Cluster cannot reference a network from this
# map — it needs a backup subnet.
#
# Only worth using when a network serves Autonomous databases alone. An ADB can
# just as well point at a key in gcp_odb_networks and share a network with your
# VM clusters. Keys share one namespace across both maps; a key in both is
# rejected before apply.
#
# gcp_odb_networks_adbs = {
#   adbnet1 = {
#     odb_network_id    = "odbnet-adb-prod"
#     network           = "projects/my-gcp-project/global/networks/default"
#     client_subnet_id  = "odb-client-adb-prod"
#     client_cidr_range = "10.30.2.0/24"
#
#     # ── optional (defaults shown) ──
#     # location            = ""                # region override (defaults to gcp_region)
#     # project             = ""                # project override (defaults to gcp_project)
#     # gcp_oracle_zone     = "us-east4-b-r1"   # Oracle zone within the region
#     # deletion_protection = true
#     # labels              = { env = "prod" }
#   }
# }

# ── Autonomous AI Databases — Serverless (optional) ───────────────────────────
# Nothing here depends on gcp_exadata_infras or gcp_vm_clusters: Oracle runs the
# fleet, so there is no Exadata Infrastructure or VM Cluster underneath and no
# infra_key. You can leave those two maps empty and deploy only Autonomous
# databases — minutes rather than the hours a VM cluster takes.
#
# network_key matches a key in EITHER gcp_odb_networks or gcp_odb_networks_adbs.
# The database is regional: it takes no gcp_oracle_zone.
#
# The ADMIN password is never written here. Export it before you apply, keyed by
# the same map key:
#
#   export TF_VAR_gcp_adb_admin_passwords='{"adb1":"YourStr0ngPass"}'
#
#   PowerShell:
#   $env:TF_VAR_gcp_adb_admin_passwords = '{"adb1":"YourStr0ngPass"}'
#
# 12-30 chars, upper + lower + digit, no double quote, cannot contain "admin".
#
# gcp_autonomous_dbs = {
#   adb1 = {
#     autonomous_database_id = "adb-prod"       # immutable, max 63 chars
#     database               = "adbprod"        # Oracle DB name, max 30 alphanumeric
#     network_key            = "net1"           # or "adbnet1" from the map above
#
#     # ── optional (defaults shown) ──
#     # display_name                    = ""        # falls back to autonomous_database_id
#     # location                        = ""        # region override
#     # project                         = ""        # project override
#     # db_workload                     = "OLTP"    # or DW, AJD, APEX
#     # license_type                    = "LICENSE_INCLUDED"   # or BRING_YOUR_OWN_LICENSE
#     # db_edition                      = "ENTERPRISE_EDITION" # or STANDARD_EDITION
#     # db_version                      = "23ai"    # or 19c
#     # compute_count                   = 2         # ECPUs, minimum 2
#     # data_storage_size_gb            = 120
#     # is_auto_scaling_enabled         = true      # burst to 3x compute_count
#     # is_storage_auto_scaling_enabled = false
#     # backup_retention_period_days    = 60        # 1-60
#     # maintenance_schedule_type       = "REGULAR" # EARLY patches a week ahead
#     # character_set                   = "AL32UTF8"
#     # n_character_set                 = "AL16UTF16"
#     # operations_insights_state       = "NOT_ENABLED"  # or ENABLED
#     # mtls_connection_required        = true      # false allows TLS-only
#     # private_endpoint_label          = "adbprod" # hostname prefix; empty = Oracle picks
#     # private_endpoint_ip             = ""        # must sit inside client_cidr_range
#     # customer_contacts               = ["dba@example.com"]
#     # deletion_protection             = true
#     # labels                          = { env = "prod" }
#   }
# }
#
# NOTE: compute_count, data_storage_size_gb, db_version, db_edition, the two
# auto-scaling flags and backup_retention_period_days are covered by an
# ignore_changes guard in modules/autonomous-db — the service rewrites them when
# it scales. Editing them here produces no plan. To resize deliberately, comment
# the field out of that lifecycle block, apply, then restore it.
