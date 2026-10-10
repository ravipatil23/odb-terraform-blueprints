# Oracle Database@AWS — reusable root module
#
# Fill in terraform.tfvars and run. You do NOT need to edit this file to add
# more networks / infras / clusters — just add entries to the maps in tfvars.
#
# Flow: ODB Network -> Exadata Infrastructure -> VM Cluster (+ optional peering)

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.42.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ── ODB Networks ────────────────────────────────────────────────────────────
module "odb_network" {
  source   = "./modules/odb-network"
  for_each = var.aws_networks

  display_name                = each.value.display_name
  availability_zone_id        = each.value.availability_zone_id
  client_subnet_cidr          = each.value.client_subnet_cidr
  backup_subnet_cidr          = each.value.backup_subnet_cidr
  s3_access                   = each.value.s3_access
  zero_etl_access             = each.value.zero_etl_access
  availability_zone           = each.value.availability_zone
  region                      = each.value.region
  custom_domain_name          = each.value.custom_domain_name
  default_dns_prefix          = each.value.default_dns_prefix
  delete_associated_resources = each.value.delete_associated_resources
  tags                        = var.tags

  # Kept in their own runs so terraform fmt does not widen the block above to
  # the length of cross_region_s3_restore_sources_access.
  sts_access          = each.value.sts_access
  kms_access          = each.value.kms_access
  s3_policy_document  = each.value.s3_policy_document
  sts_policy_document = each.value.sts_policy_document
  kms_policy_document = each.value.kms_policy_document

  cross_region_s3_restore_sources_access = each.value.cross_region_s3_restore_sources_access
}

# ── Exadata Infrastructures ───────────────────────────────────────────────────
module "exadata_infra" {
  source   = "./modules/exadata-infra"
  for_each = var.aws_infras

  display_name                        = each.value.display_name
  shape                               = each.value.shape
  compute_count                       = each.value.compute_count
  storage_count                       = each.value.storage_count
  availability_zone_id                = each.value.availability_zone_id
  availability_zone                   = each.value.availability_zone
  region                              = each.value.region
  database_server_type                = each.value.database_server_type
  storage_server_type                 = each.value.storage_server_type
  customer_contacts                   = each.value.customer_contacts
  mw_preference                       = each.value.mw_preference
  mw_patching_mode                    = each.value.mw_patching_mode
  mw_is_custom_action_timeout_enabled = each.value.mw_is_custom_action_timeout_enabled
  mw_custom_action_timeout_in_mins    = each.value.mw_custom_action_timeout_in_mins
  mw_lead_time_in_weeks               = each.value.mw_lead_time_in_weeks
  mw_days_of_week                     = each.value.mw_days_of_week
  mw_months                           = each.value.mw_months
  mw_hours_of_day                     = each.value.mw_hours_of_day
  mw_weeks_of_month                   = each.value.mw_weeks_of_month
  tags                                = var.tags
}

# ── Resource lookup ───────────────────────────────────────────────────────────
# One keyspace covering resources this blueprint creates and resources that
# already exist (see the existing_* maps in terraform.tfvars), so network_ref /
# infra_ref resolve the same way whichever side a resource lives on.
#
# Merged rather than a conditional on purpose: both branches of a ?: get
# evaluated, so indexing a module for a key that was never created fails even on
# the branch that is not taken.
locals {
  odb_network_ids = merge(
    { for k, m in module.odb_network : k => m.network_id },
    var.existing_odb_network_ids,
  )
  infra_ids = merge(
    { for k, m in module.exadata_infra : k => m.infra_id },
    var.existing_infra_ids,
  )
}

# Auto-discovered DB servers per cluster, filtered to the ones actually free.
#
# aws_odb_db_servers returns EVERY server on the infrastructure, including those
# existing VM clusters already hold. On an infrastructure this blueprint just
# created that is harmless - nothing is allocated yet - but on one that already
# hosts clusters it hands back servers that are taken, and the create fails.
#
# That is the normal state of an infrastructure created outside Terraform (the
# existing_infra_ids case), and it also bites the second cluster you put on an
# infrastructure this blueprint made.
#
# vm_cluster_ids / autonomous_vm_cluster_ids are the allocation record: empty
# means the server is unclaimed.
locals {
  auto_db_servers = {
    for k, d in data.aws_odb_db_servers.this : k => [
      for s in d.db_servers : s.id
      if length(s.vm_cluster_ids) == 0 && length(s.autonomous_vm_cluster_ids) == 0
    ]
  }

  # Same filter for the Autonomous clusters, off their own data source.
  auto_db_servers_autonomous = {
    for k, d in data.aws_odb_db_servers.autonomous : k => [
      for s in d.db_servers : s.id
      if length(s.vm_cluster_ids) == 0 && length(s.autonomous_vm_cluster_ids) == 0
    ]
  }

  # Both kinds share one infrastructure, so an ExaDB-D cluster and an ADB-D
  # cluster in the same apply would otherwise be handed the same free servers.
  all_auto_db_servers = merge(local.auto_db_servers, local.auto_db_servers_autonomous)
}

# Every server on the infrastructure is already spoken for. Creating the cluster
# with an empty db_servers list fails at the API with something far less
# obvious, so say it here.
check "auto_db_servers_available" {
  assert {
    condition = alltrue([for k, v in local.all_auto_db_servers : length(v) > 0])
    error_message = format(
      "No unallocated DB servers on the infrastructure for these clusters: %s. Every server is already held by another VM cluster. Add capacity to the infrastructure, or use db_servers_mode = \"manual\" to place the cluster deliberately.",
      join(", ", [for k, v in local.all_auto_db_servers : k if length(v) == 0]),
    )
  }
}

# A key defined in both maps would create the resource *and* wire everything to
# the pre-existing one, leaving the new resource orphaned. Catch it up front.
check "no_duplicate_network_keys" {
  assert {
    condition = length(setintersection(keys(var.aws_networks), keys(var.existing_odb_network_ids))) == 0
    error_message = format(
      "These keys appear in both aws_networks and existing_odb_network_ids: %s. Keep each network in one map only — describe it in aws_networks to create it, or give its ID in existing_odb_network_ids to reuse it.",
      join(", ", setintersection(keys(var.aws_networks), keys(var.existing_odb_network_ids))),
    )
  }
}

check "no_duplicate_infra_keys" {
  assert {
    condition = length(setintersection(keys(var.aws_infras), keys(var.existing_infra_ids))) == 0
    error_message = format(
      "These keys appear in both aws_infras and existing_infra_ids: %s. Keep each infrastructure in one map only — describe it in aws_infras to create it, or give its ID in existing_infra_ids to reuse it.",
      join(", ", setintersection(keys(var.aws_infras), keys(var.existing_infra_ids))),
    )
  }
}

# ── DB Server IDs ─────────────────────────────────────────────────────────────
# Auto-discovered per cluster from the Exadata Infrastructure when
# db_servers_mode = "auto" (the default). Set "manual" to supply your own.
data "aws_odb_db_servers" "this" {
  depends_on                      = [module.exadata_infra]
  for_each                        = { for k, v in var.aws_clusters : k => v if v.db_servers_mode == "auto" }
  cloud_exadata_infrastructure_id = local.infra_ids[each.value.infra_ref]
}

# Same lookup for Autonomous clusters. A separate data source rather than a
# shared one: the two maps have independent keyspaces, so "vmc1" in aws_clusters
# and "vmc1" in aws_autonomous_clusters are different clusters that may sit on
# different infrastructures.
data "aws_odb_db_servers" "autonomous" {
  depends_on                      = [module.exadata_infra]
  for_each                        = { for k, v in var.aws_autonomous_clusters : k => v if v.db_servers_mode == "auto" }
  cloud_exadata_infrastructure_id = local.infra_ids[each.value.infra_ref]
}

# ── Network Peerings (optional) ───────────────────────────────────────────────
module "peering" {
  source   = "./modules/peering"
  for_each = var.aws_peerings

  display_name    = each.value.display_name
  odb_network_id  = local.odb_network_ids[each.value.network_ref]
  peer_network_id = each.value.peer_network_id
  region          = each.value.region
  tags            = var.tags

  depends_on = [module.odb_network]
}

# ── VM Clusters ───────────────────────────────────────────────────────────────
module "vm_cluster" {
  source   = "./modules/vm-cluster"
  for_each = var.aws_clusters

  display_name                      = each.value.display_name
  cpu_core_count                    = each.value.cpu_core_count
  gi_version                        = each.value.gi_version
  hostname_prefix                   = each.value.hostname_prefix
  license_model                     = each.value.license_model
  ssh_public_keys                   = each.value.ssh_public_keys
  cloud_exadata_infrastructure_id   = local.infra_ids[each.value.infra_ref]
  odb_network_id                    = local.odb_network_ids[each.value.network_ref]
  db_servers                        = each.value.db_servers_mode == "auto" ? local.auto_db_servers[each.key] : each.value.db_servers
  dco_is_diagnostics_events_enabled = each.value.dco_is_diagnostics_events_enabled
  dco_is_health_monitoring_enabled  = each.value.dco_is_health_monitoring_enabled
  dco_is_incident_logs_enabled      = each.value.dco_is_incident_logs_enabled
  cluster_name                      = each.value.cluster_name
  timezone                          = each.value.timezone
  data_storage_size_in_tbs          = each.value.data_storage_size_in_tbs
  db_node_storage_size_in_gbs       = each.value.db_node_storage_size_in_gbs
  memory_size_in_gbs                = each.value.memory_size_in_gbs
  scan_listener_port_tcp            = each.value.scan_listener_port_tcp
  is_local_backup_enabled           = each.value.is_local_backup_enabled
  is_sparse_diskgroup_enabled       = each.value.is_sparse_diskgroup_enabled
  tags                              = var.tags

  depends_on = [module.odb_network, module.exadata_infra]
}

# ── Autonomous VM Clusters (optional) ─────────────────────────────────────────
# ADB-D: hosts Autonomous Container Databases rather than DB Homes/CDBs/PDBs.
# Shares the Exadata infrastructure and ODB network with the ExaDB-D clusters
# above — infra_ref / network_ref key into the same maps.
#
# Leave aws_autonomous_clusters empty and nothing here applies.
module "autonomous_vm_cluster" {
  source   = "./modules/autonomous-vm-cluster"
  for_each = var.aws_autonomous_clusters

  display_name                    = each.value.display_name
  cloud_exadata_infrastructure_id = local.infra_ids[each.value.infra_ref]
  odb_network_id                  = local.odb_network_ids[each.value.network_ref]
  db_servers                      = each.value.db_servers_mode == "auto" ? local.auto_db_servers_autonomous[each.key] : each.value.db_servers

  autonomous_data_storage_size_in_tbs   = each.value.autonomous_data_storage_size_in_tbs
  cpu_core_count_per_node               = each.value.cpu_core_count_per_node
  memory_per_oracle_compute_unit_in_gbs = each.value.memory_per_oracle_compute_unit_in_gbs
  total_container_databases             = each.value.total_container_databases

  scan_listener_port_tls     = each.value.scan_listener_port_tls
  scan_listener_port_non_tls = each.value.scan_listener_port_non_tls

  license_model              = each.value.license_model
  is_mtls_enabled_vm_cluster = each.value.is_mtls_enabled_vm_cluster
  time_zone                  = each.value.time_zone
  description                = each.value.description

  mw_preference         = each.value.mw_preference
  mw_lead_time_in_weeks = each.value.mw_lead_time_in_weeks
  mw_days_of_week       = each.value.mw_days_of_week
  mw_months             = each.value.mw_months
  mw_hours_of_day       = each.value.mw_hours_of_day
  mw_weeks_of_month     = each.value.mw_weeks_of_month

  tags = var.tags

  depends_on = [module.odb_network, module.exadata_infra]
}
