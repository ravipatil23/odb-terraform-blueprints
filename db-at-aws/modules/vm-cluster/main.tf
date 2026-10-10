terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.42.0" }
  }
}

resource "aws_odb_cloud_vm_cluster" "this" {
  display_name    = var.display_name
  cpu_core_count  = var.cpu_core_count
  gi_version      = var.gi_version
  hostname_prefix = var.hostname_prefix
  license_model   = var.license_model

  cloud_exadata_infrastructure_id = var.cloud_exadata_infrastructure_id != "" ? var.cloud_exadata_infrastructure_id : null
  odb_network_id                  = var.odb_network_id != "" ? var.odb_network_id : null

  ssh_public_keys = var.ssh_public_keys

  # db_servers wired from root: data.aws_odb_db_servers (auto) or supplied list (manual)
  db_servers = length(var.db_servers) > 0 ? var.db_servers : null

  data_collection_options {
    is_diagnostics_events_enabled = var.dco_is_diagnostics_events_enabled
    is_health_monitoring_enabled  = var.dco_is_health_monitoring_enabled
    is_incident_logs_enabled      = var.dco_is_incident_logs_enabled
  }

  cluster_name                = var.cluster_name != "" ? var.cluster_name : null
  timezone                    = var.timezone != "" ? var.timezone : null
  data_storage_size_in_tbs    = var.data_storage_size_in_tbs
  db_node_storage_size_in_gbs = var.db_node_storage_size_in_gbs
  memory_size_in_gbs          = var.memory_size_in_gbs
  scan_listener_port_tcp      = var.scan_listener_port_tcp
  is_local_backup_enabled     = var.is_local_backup_enabled
  is_sparse_diskgroup_enabled = var.is_sparse_diskgroup_enabled

  tags = var.tags

  timeouts {
    create = "12h"
    update = "2h"
    delete = "8h"
  }

  lifecycle {
    # Delete protection. The VM cluster holds your databases — destroying it
    # destroys them, and no amount of re-applying brings the data back.
    #
    # This has to be a literal — prevent_destroy rejects variable references, so
    # unlike the GCP blueprint's deletion_protection input it cannot be flipped
    # from terraform.tfvars. To tear this down deliberately, delete this
    # lifecycle block, apply, then destroy.
    prevent_destroy = true

    # Every argument below is ForceNew, so drift proposes destroying the cluster
    # rather than updating it. These are the ones that move without Terraform:
    # elastic scaling done from the console, key rotation on the nodes, and -
    # with db_servers_mode = "auto" - the data.aws_odb_db_servers lookup
    # returning a different set after the infra changes.
    #
    # To resize *through* Terraform, remove the relevant entry first.
    ignore_changes = [
      db_servers,
      cpu_core_count,
      memory_size_in_gbs,
      db_node_storage_size_in_gbs,
      data_storage_size_in_tbs,
      is_local_backup_enabled,
      is_sparse_diskgroup_enabled,
      ssh_public_keys,

      # gi_version is deliberately left out. The AWS provider stores the
      # resolved release separately as gi_version_computed and reconstructs your
      # major version on read, so it does not drift - guarding it would only
      # hide a version change you made on purpose. Uncomment only if you see a
      # plan actually proposing replacement over it.
      # gi_version,
    ]
  }
}
