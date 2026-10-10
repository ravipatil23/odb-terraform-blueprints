output "db_home_id" {
  description = "OCID of the DB Home. Feed this to the cdb template as db_home_id."
  value       = oci_database_db_home.this.id
}

output "display_name" {
  description = "Display name of the DB Home."
  value       = oci_database_db_home.this.display_name
}

output "db_version" {
  description = "Oracle version running in this home."
  value       = oci_database_db_home.this.db_version
}
