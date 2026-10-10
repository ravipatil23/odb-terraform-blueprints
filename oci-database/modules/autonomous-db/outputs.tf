output "adb_id" {
  description = "OCID of the Autonomous Database."
  value       = oci_database_autonomous_database.this.id
}

output "db_name" {
  description = "Database name."
  value       = oci_database_autonomous_database.this.db_name
}

output "display_name" {
  description = "Display name."
  value       = oci_database_autonomous_database.this.display_name
}

output "acd_id" {
  description = "OCID of the parent Autonomous Container Database."
  value       = oci_database_autonomous_database.this.autonomous_container_database_id
}

output "state" {
  description = "Lifecycle state, e.g. AVAILABLE."
  value       = oci_database_autonomous_database.this.state
}

output "private_endpoint" {
  description = "Private endpoint hostname. On ADB-D this follows the Autonomous VM Cluster's placement on the ODB network."
  value       = oci_database_autonomous_database.this.private_endpoint
}

output "uses_vault_secret" {
  description = "True when the ADMIN password is a Vault secret reference rather than a literal held in state."
  value       = oci_database_autonomous_database.this.secret_id != null && oci_database_autonomous_database.this.secret_id != ""
}

# connection_strings is a list the service fills in after provisioning. try()
# rather than a bare [0]: it is empty while the database is still coming up, and
# indexing it directly would fail the very apply that created the database.
output "connection_strings" {
  description = "TNS aliases by consumer group. Empty until the database reaches AVAILABLE."
  value = {
    high      = try(oci_database_autonomous_database.this.connection_strings[0].high, null)
    medium    = try(oci_database_autonomous_database.this.connection_strings[0].medium, null)
    low       = try(oci_database_autonomous_database.this.connection_strings[0].low, null)
    dedicated = try(oci_database_autonomous_database.this.connection_strings[0].dedicated, null)
  }
}

output "connection_urls" {
  description = "Service console, APEX and Database Actions URLs. Empty until the database reaches AVAILABLE."
  value       = try(oci_database_autonomous_database.this.connection_urls[0], null)
}
