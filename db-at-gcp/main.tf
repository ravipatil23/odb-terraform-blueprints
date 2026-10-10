# Oracle Database@GCP — reusable root module
#
# Fill in terraform.tfvars and run. Add entries to the maps to scale — no need
# to edit this file.
#
# Flow: ODB Network (+ client/backup subnets) -> Exadata Infrastructure -> VM Cluster
#       ODB Network (client subnet only)      -> Autonomous AI Database (Serverless)
#
# The two flows are independent. Serverless runs on Oracle's fleet, so it needs
# a network and nothing else — no Exadata Infrastructure, no VM Cluster, and no
# backup subnet. Leave gcp_exadata_infras and gcp_vm_clusters empty and this
# deploys Autonomous databases alone.

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source = "hashicorp/google"
      # 7.0 is the first release carrying odb_network / odb_subnet on
      # google_oracle_database_autonomous_database. Provider requirements are
      # static, so this floor applies even when gcp_autonomous_dbs is empty —
      # the Exadata side of the blueprint is unaffected either way.
      version = ">= 7.0.0"
    }
  }
}

provider "google" {
  project = var.gcp_project
  region  = var.gcp_region
}

# ── ODB Networks ────────────────────────────────────────────────────────────
module "odb_network" {
  source   = "./modules/odb-network"
  for_each = var.gcp_odb_networks

  odb_network_id      = each.value.odb_network_id
  location            = each.value.location != "" ? each.value.location : var.gcp_region
  network             = each.value.network
  project             = each.value.project != "" ? each.value.project : var.gcp_project
  gcp_oracle_zone     = each.value.gcp_oracle_zone
  client_subnet_id    = each.value.client_subnet_id
  client_cidr_range   = each.value.client_cidr_range
  backup_subnet_id    = each.value.backup_subnet_id
  backup_cidr_range   = each.value.backup_cidr_range
  deletion_protection = each.value.deletion_protection
  labels              = each.value.labels
}

# ── Exadata Infrastructures ───────────────────────────────────────────────────
module "exadata_infra" {
  source   = "./modules/exadata-infra"
  for_each = var.gcp_exadata_infras

  cloud_exadata_infrastructure_id     = each.value.cloud_exadata_infrastructure_id
  location                            = each.value.location != "" ? each.value.location : var.gcp_region
  display_name                        = each.value.display_name
  gcp_oracle_zone                     = each.value.gcp_oracle_zone
  project                             = each.value.project != "" ? each.value.project : var.gcp_project
  shape                               = each.value.shape
  compute_count                       = each.value.compute_count
  storage_count                       = each.value.storage_count
  total_storage_size_gb               = each.value.total_storage_size_gb
  customer_contacts                   = each.value.customer_contacts
  mw_preference                       = each.value.mw_preference
  mw_patching_mode                    = each.value.mw_patching_mode
  mw_is_custom_action_timeout_enabled = each.value.mw_is_custom_action_timeout_enabled
  mw_custom_action_timeout_mins       = each.value.mw_custom_action_timeout_mins
  mw_lead_time_week                   = each.value.mw_lead_time_week
  mw_days_of_week                     = each.value.mw_days_of_week
  mw_months                           = each.value.mw_months
  mw_hours_of_day                     = each.value.mw_hours_of_day
  mw_weeks_of_month                   = each.value.mw_weeks_of_month
  deletion_protection                 = each.value.deletion_protection
  labels                              = each.value.labels
}

# ── DB Server OCIDs ───────────────────────────────────────────────────────────
# Auto-discovered per cluster from the Exadata Infrastructure.
data "google_oracle_database_db_servers" "this" {
  depends_on                   = [module.exadata_infra]
  for_each                     = var.gcp_vm_clusters
  location                     = each.value.location != "" ? each.value.location : var.gcp_region
  project                      = each.value.project != "" ? each.value.project : var.gcp_project
  cloud_exadata_infrastructure = module.exadata_infra[each.value.infra_key].infra_self_link
}

# ── VM Clusters ───────────────────────────────────────────────────────────────
# infra_key / network_key must match keys in gcp_exadata_infras / gcp_odb_networks.
module "vm_cluster" {
  source   = "./modules/vm-cluster"
  for_each = var.gcp_vm_clusters

  cloud_vm_cluster_id      = each.value.cloud_vm_cluster_id
  display_name             = each.value.display_name
  location                 = each.value.location != "" ? each.value.location : var.gcp_region
  project                  = each.value.project != "" ? each.value.project : var.gcp_project
  exadata_infrastructure   = module.exadata_infra[each.value.infra_key].infra_self_link
  odb_network              = module.odb_network[each.value.network_key].odb_network_name
  odb_subnet               = module.odb_network[each.value.network_key].client_subnet_name
  backup_odb_subnet        = module.odb_network[each.value.network_key].backup_subnet_name
  db_server_ocids          = data.google_oracle_database_db_servers.this[each.key].db_servers[*].properties[0].ocid
  hostname_prefix          = each.value.hostname_prefix
  cpu_core_count           = each.value.cpu_core_count
  memory_size_gb           = each.value.memory_size_gb
  db_node_storage_size_gb  = each.value.db_node_storage_size_gb
  data_storage_size_tb     = each.value.data_storage_size_tb
  gi_version               = each.value.gi_version
  license_type             = each.value.license_type
  ssh_public_keys          = each.value.ssh_public_keys
  local_backup_enabled     = each.value.local_backup_enabled
  sparse_diskgroup_enabled = each.value.sparse_diskgroup_enabled
  cluster_name             = each.value.cluster_name
  node_count               = each.value.node_count
  ocpu_count               = each.value.ocpu_count
  disk_redundancy          = each.value.disk_redundancy
  time_zone                = each.value.time_zone
  scan_listener_port_tcp   = each.value.scan_listener_port_tcp
  dco_diagnostics          = each.value.dco_diagnostics
  dco_health               = each.value.dco_health
  dco_incident_logs        = each.value.dco_incident_logs
  deletion_protection      = each.value.deletion_protection
  labels                   = each.value.labels

  depends_on = [module.odb_network, module.exadata_infra]
}

# ── ODB Networks — Autonomous AI Database Serverless only ─────────────────────
# Built from a module that creates no backup subnet: an Autonomous Database
# never uses one. A VM Cluster cannot reference these networks — it needs a
# backup subnet, and gcp_vm_clusters resolves network_key against
# gcp_odb_networks only, so pointing one here fails with "Invalid index".
module "odb_network_adbs" {
  source   = "./modules/odb-network-adbs"
  for_each = var.gcp_odb_networks_adbs

  odb_network_id      = each.value.odb_network_id
  location            = each.value.location != "" ? each.value.location : var.gcp_region
  network             = each.value.network
  project             = each.value.project != "" ? each.value.project : var.gcp_project
  gcp_oracle_zone     = each.value.gcp_oracle_zone
  client_subnet_id    = each.value.client_subnet_id
  client_cidr_range   = each.value.client_cidr_range
  deletion_protection = each.value.deletion_protection
  labels              = each.value.labels
}

# Both network kinds expose the same two values an Autonomous Database needs, so
# an ADB can reference either without caring which module built it.
#
# Merged rather than a conditional on purpose: both branches of a ?: are
# evaluated, so indexing a module for a key that was never created fails even on
# the branch that is not taken.
locals {
  adb_odb_networks = merge(
    { for k, v in module.odb_network : k => {
      odb_network_name   = v.odb_network_name
      client_subnet_name = v.client_subnet_name
    } },
    { for k, v in module.odb_network_adbs : k => {
      odb_network_name   = v.odb_network_name
      client_subnet_name = v.client_subnet_name
    } },
  )
}

# A key defined in both network maps would build two networks and silently
# resolve network_key to the ADB-S one, because merge() takes the later value.
# Catch it before apply.
check "no_duplicate_odb_network_keys" {
  assert {
    condition = length(setintersection(keys(var.gcp_odb_networks), keys(var.gcp_odb_networks_adbs))) == 0
    error_message = format(
      "These keys appear in both gcp_odb_networks and gcp_odb_networks_adbs: %s. Keep each network in one map only - gcp_odb_networks when a VM Cluster needs it, gcp_odb_networks_adbs when only Autonomous databases do.",
      join(", ", setintersection(keys(var.gcp_odb_networks), keys(var.gcp_odb_networks_adbs))),
    )
  }
}

# ── Autonomous AI Databases (Serverless) ──────────────────────────────────────
# network_key matches a key in EITHER gcp_odb_networks or gcp_odb_networks_adbs.
# Serverless depends on the ODB Network alone — no Exadata Infrastructure, no VM
# Cluster, no backup subnet.
module "autonomous_db" {
  source   = "./modules/autonomous-db"
  for_each = var.gcp_autonomous_dbs

  autonomous_database_id = each.value.autonomous_database_id
  location               = each.value.location != "" ? each.value.location : var.gcp_region
  project                = each.value.project != "" ? each.value.project : var.gcp_project
  database               = each.value.database
  display_name           = each.value.display_name

  # Indexed, not looked up: a missing password should stop the plan rather than
  # reach the provider as null. The check below names the offending key first.
  admin_password = var.gcp_adb_admin_passwords[each.key]

  odb_network = local.adb_odb_networks[each.value.network_key].odb_network_name
  odb_subnet  = local.adb_odb_networks[each.value.network_key].client_subnet_name

  db_workload  = each.value.db_workload
  license_type = each.value.license_type
  db_edition   = each.value.db_edition
  db_version   = each.value.db_version

  compute_count                   = each.value.compute_count
  data_storage_size_gb            = each.value.data_storage_size_gb
  is_auto_scaling_enabled         = each.value.is_auto_scaling_enabled
  is_storage_auto_scaling_enabled = each.value.is_storage_auto_scaling_enabled

  backup_retention_period_days = each.value.backup_retention_period_days
  maintenance_schedule_type    = each.value.maintenance_schedule_type

  character_set             = each.value.character_set
  n_character_set           = each.value.n_character_set
  operations_insights_state = each.value.operations_insights_state

  mtls_connection_required = each.value.mtls_connection_required
  private_endpoint_label   = each.value.private_endpoint_label
  private_endpoint_ip      = each.value.private_endpoint_ip
  customer_contacts        = each.value.customer_contacts

  deletion_protection = each.value.deletion_protection
  labels              = each.value.labels

  depends_on = [module.odb_network, module.odb_network_adbs]
}

# Passwords come from the environment, so a typo in a key is easy to make and
# the raw failure ("key ... does not exist") does not say which map is short.
#
# The password map is sensitive, so every value derived from it carries that
# mark - including its key names, which an assertion may not report. Only the
# keys are unwrapped here; the passwords themselves are never touched.
locals {
  adb_missing_passwords = setsubtract(
    keys(var.gcp_autonomous_dbs),
    nonsensitive(keys(var.gcp_adb_admin_passwords)),
  )
}

check "adb_passwords_present" {
  assert {
    condition = length(local.adb_missing_passwords) == 0
    error_message = format(
      "No ADMIN password supplied for these gcp_autonomous_dbs keys: %s. Set them with TF_VAR_gcp_adb_admin_passwords='{\"key\":\"...\"}' - never in terraform.tfvars.",
      join(", ", local.adb_missing_passwords),
    )
  }
}
