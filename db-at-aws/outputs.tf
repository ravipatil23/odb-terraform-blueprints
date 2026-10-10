output "odb_networks" {
  description = "ODB Network details keyed by instance name."
  value = { for k, v in module.odb_network : k => {
    network_id  = v.network_id
    network_arn = v.network_arn

    # Effective values: blank sts_access/kms_access inputs adopt what the
    # service assigned, so read them back here rather than from the config.
    s3_access  = v.s3_access
    sts_access = v.sts_access
    kms_access = v.kms_access
  } }
}

output "exadata_infras" {
  description = "Exadata Infrastructure details keyed by instance name."
  value = { for k, v in module.exadata_infra : k => {
    infra_id  = v.infra_id
    infra_arn = v.infra_arn
  } }
}

output "peerings" {
  description = "Network Peering details keyed by instance name."
  value = { for k, v in module.peering : k => {
    peering_connection_id = v.peering_connection_id
  } }
}

output "vm_clusters" {
  description = "VM Cluster details keyed by instance name."
  value = { for k, v in module.vm_cluster : k => {
    vm_cluster_id = v.vm_cluster_id
    ocid          = v.ocid
  } }
}

output "db_servers" {
  description = "DB Server IDs per cluster, keyed by cluster instance name."
  value       = { for k, v in data.aws_odb_db_servers.this : k => v.db_servers[*].id }
}

output "autonomous_vm_clusters" {
  description = "Autonomous VM Clusters (ADB-D) per key. ocid is the handle for creating Autonomous Container Databases with the oracle/oci provider."
  value = {
    for k, m in module.autonomous_vm_cluster : k => {
      autonomous_vm_cluster_id = m.autonomous_vm_cluster_id
      ocid                     = m.ocid
      hostname                 = m.hostname
      domain                   = m.domain
      cpu_core_count           = m.cpu_core_count
      available_cpus           = m.available_cpus
    }
  }
}
