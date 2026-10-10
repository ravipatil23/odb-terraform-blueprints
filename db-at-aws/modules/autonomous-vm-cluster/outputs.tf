output "autonomous_vm_cluster_id" {
  description = "ID of the Autonomous VM cluster."
  value       = aws_odb_cloud_autonomous_vm_cluster.this.id
}

output "autonomous_vm_cluster_arn" {
  description = "ARN of the Autonomous VM cluster."
  value       = aws_odb_cloud_autonomous_vm_cluster.this.arn
}

output "ocid" {
  description = "OCI OCID of the Autonomous VM cluster — the handle for creating Autonomous Container Databases on it with the oracle/oci provider."
  value       = aws_odb_cloud_autonomous_vm_cluster.this.ocid
}

output "display_name" {
  description = "Display name."
  value       = aws_odb_cloud_autonomous_vm_cluster.this.display_name
}

output "hostname" {
  description = "Cluster hostname."
  value       = aws_odb_cloud_autonomous_vm_cluster.this.hostname
}

output "domain" {
  description = "Cluster DNS domain."
  value       = aws_odb_cloud_autonomous_vm_cluster.this.domain
}

# Capacity the service reports back — useful for checking what a sizing change
# actually produced, since most sizing arguments are ForceNew and guarded by
# ignore_changes in main.tf.
output "cpu_core_count" {
  description = "Total CPU cores across the cluster, as reported by the service."
  value       = aws_odb_cloud_autonomous_vm_cluster.this.cpu_core_count
}

output "available_cpus" {
  description = "CPU cores still unallocated to Autonomous Container Databases."
  value       = aws_odb_cloud_autonomous_vm_cluster.this.available_cpus
}

output "available_autonomous_data_storage_size_in_tbs" {
  description = "Autonomous data storage still unallocated, in TB."
  value       = aws_odb_cloud_autonomous_vm_cluster.this.available_autonomous_data_storage_size_in_tbs
}
