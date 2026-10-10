output "pdb_id" {
  description = "OCID of the pluggable database."
  value       = oci_database_pluggable_database.this.id
}

output "pdb_name" {
  description = "PDB name."
  value       = oci_database_pluggable_database.this.pdb_name
}

output "connection_strings" {
  description = "Connection strings for the PDB, as reported by the service."
  value       = oci_database_pluggable_database.this.connection_strings
}
