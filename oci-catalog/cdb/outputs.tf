output "cdb_id" {
  description = "OCID of the container database. Feed this to the pdb template as container_database_id."
  value       = oci_database_database.this.id
}

output "db_name" {
  description = "CDB name."
  value       = var.db_name
}

output "db_unique_name" {
  description = "DB unique name, as resolved by the service."
  value       = oci_database_database.this.db_unique_name
}
