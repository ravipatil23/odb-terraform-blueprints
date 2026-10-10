# ─────────────────────────────────────────────────────────────────────────────
# autonomous-vm-cluster — Autonomous Database on Dedicated Exadata (ADB-D)
#
# The Autonomous counterpart of modules/vm-cluster. Both hang off the same
# Exadata infrastructure and ODB network, and both take DB server IDs, but they
# host different things:
#
#   vm-cluster             -> DB Homes / CDBs / PDBs   (see ../../oci-database)
#   autonomous-vm-cluster  -> Autonomous Container Databases / Autonomous DBs
#
# Sizing is expressed per node and per Oracle Compute Unit rather than as whole
# cluster totals, which is why the argument set barely overlaps the ExaDB-D one.
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.42.0"
    }
  }
}

resource "aws_odb_cloud_autonomous_vm_cluster" "this" {
  display_name                    = var.display_name
  cloud_exadata_infrastructure_id = var.cloud_exadata_infrastructure_id
  odb_network_id                  = var.odb_network_id
  db_servers                      = length(var.db_servers) > 0 ? var.db_servers : null

  autonomous_data_storage_size_in_tbs   = var.autonomous_data_storage_size_in_tbs
  cpu_core_count_per_node               = var.cpu_core_count_per_node
  memory_per_oracle_compute_unit_in_gbs = var.memory_per_oracle_compute_unit_in_gbs
  total_container_databases             = var.total_container_databases

  scan_listener_port_tls     = var.scan_listener_port_tls
  scan_listener_port_non_tls = var.scan_listener_port_non_tls

  license_model              = var.license_model
  is_mtls_enabled_vm_cluster = var.is_mtls_enabled_vm_cluster
  time_zone                  = var.time_zone != "" ? var.time_zone : null
  description                = var.description != "" ? var.description : null

  # Required block. Unlike ExaDB-D - where the maintenance window sits on the
  # *infrastructure* - an Autonomous VM cluster carries its own.
  maintenance_window {
    preference         = var.mw_preference
    lead_time_in_weeks = var.mw_lead_time_in_weeks > 0 ? var.mw_lead_time_in_weeks : null
    days_of_week       = length(var.mw_days_of_week) > 0 ? [for d in var.mw_days_of_week : { name = d }] : null
    months             = length(var.mw_months) > 0 ? [for m in var.mw_months : { name = m }] : null
    hours_of_day       = length(var.mw_hours_of_day) > 0 ? var.mw_hours_of_day : null
    weeks_of_month     = length(var.mw_weeks_of_month) > 0 ? var.mw_weeks_of_month : null
  }

  tags = var.tags

  timeouts {
    create = "12h"
    update = "2h"
    delete = "8h"
  }

  lifecycle {
    # Delete protection. The cluster holds your Autonomous Databases —
    # destroying it destroys them, and re-applying does not bring the data back.
    #
    # This has to be a literal — prevent_destroy rejects variable references, so
    # unlike the GCP blueprint's deletion_protection input it cannot be flipped
    # from terraform.tfvars. To tear this down deliberately, delete this
    # lifecycle block, apply, then destroy.
    prevent_destroy = true

    # Nearly every argument here is ForceNew, so drift proposes destroying the
    # cluster rather than updating it. These are the ones that move without
    # Terraform: Autonomous scaling done from the console or by the service, and
    # — with db_servers_mode = "auto" — the data.aws_odb_db_servers lookup
    # returning a different set after the infrastructure changes.
    #
    # To resize *through* Terraform, remove the relevant entry first.
    ignore_changes = [
      db_servers,
      cpu_core_count_per_node,
      memory_per_oracle_compute_unit_in_gbs,
      autonomous_data_storage_size_in_tbs,
      total_container_databases,
    ]
  }
}
