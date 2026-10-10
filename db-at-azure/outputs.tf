output "vnets" {
  description = "VNet details keyed by instance name."
  value = { for k, v in module.vnet : k => {
    vnet_id   = v.vnet_id
    subnet_id = v.subnet_id
  } }
}

output "exadata_infras" {
  description = "Exadata Infrastructure details keyed by instance name."
  value = { for k, v in module.exadata_infra : k => {
    infra_id   = v.infra_id
    infra_name = v.infra_name
  } }
}

output "vm_clusters" {
  description = "VM Cluster details keyed by instance name."
  value = { for k, v in module.vm_cluster : k => {
    cluster_id = v.cluster_id
    ocid       = v.ocid
  } }
}

output "resource_anchors" {
  description = "Resource Anchor details keyed by the azure_resource_anchors key."
  value = { for k, m in module.resource_anchor : k => {
    id                    = m.id
    location              = m.location
    linked_compartment_id = m.linked_compartment_id
  } }
}

output "network_anchors" {
  description = "Network Anchor details keyed by the azure_network_anchors key."
  value = { for k, m in module.network_anchor : k => {
    id   = m.id
    name = m.name
  } }
}

output "autonomous_databases" {
  description = "Autonomous Database (Serverless) details keyed by the azure_autonomous_dbs key."
  value = { for k, m in module.autonomous_db : k => {
    id   = m.autonomous_database_id
    name = m.autonomous_database_name
  } }
}
