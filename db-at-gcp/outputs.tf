output "odb_networks" {
  description = "ODB Network details keyed by instance name."
  value = { for k, v in module.odb_network : k => {
    odb_network_name   = v.odb_network_name
    client_subnet_name = v.client_subnet_name
    backup_subnet_name = v.backup_subnet_name
  } }
}

output "exadata_infras" {
  description = "Exadata Infrastructure details keyed by instance name."
  value = { for k, v in module.exadata_infra : k => {
    infra_name = v.infra_name
    ocid       = v.ocid
  } }
}

output "vm_clusters" {
  description = "VM Cluster details keyed by instance name."
  value = { for k, v in module.vm_cluster : k => {
    vm_cluster_name = v.vm_cluster_name
    ocid            = v.ocid
  } }
}

output "db_servers" {
  description = "DB Server OCIDs per cluster, keyed by cluster instance name."
  value       = { for k, v in data.google_oracle_database_db_servers.this : k => v.db_servers[*].properties[0].ocid }
}

output "odb_networks_adbs" {
  description = "ADB-S-only ODB Network details keyed by instance name. No backup subnet exists on these."
  value = { for k, v in module.odb_network_adbs : k => {
    odb_network_name   = v.odb_network_name
    client_subnet_name = v.client_subnet_name
  } }
}

output "autonomous_databases" {
  description = "Autonomous AI Database (Serverless) details keyed by the gcp_autonomous_dbs key."
  value = { for k, v in module.autonomous_db : k => {
    autonomous_database_id   = v.autonomous_database_id
    autonomous_database_name = v.autonomous_database_name
    ocid                     = v.ocid
  } }
}
