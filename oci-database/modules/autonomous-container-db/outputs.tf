output "acd_id" {
  description = "OCID of the Autonomous Container Database — the handle Autonomous Databases attach to."
  value       = oci_database_autonomous_container_database.this.id
}

output "display_name" {
  description = "Display name of the container."
  value       = oci_database_autonomous_container_database.this.display_name
}

output "db_name" {
  description = "Container database name, as assigned (generated when db_name was left blank)."
  value       = oci_database_autonomous_container_database.this.db_name
}

output "db_version" {
  description = "Running Oracle version. Reflects Oracle's patching, not the config — db_version drift is ignored."
  value       = oci_database_autonomous_container_database.this.db_version
}

output "compartment_id" {
  description = "Compartment the container landed in (inherited from the cluster when left blank)."
  value       = oci_database_autonomous_container_database.this.compartment_id
}

output "availability_domain" {
  description = "Availability domain of the container."
  value       = oci_database_autonomous_container_database.this.availability_domain
}

output "state" {
  description = "Lifecycle state, e.g. AVAILABLE."
  value       = oci_database_autonomous_container_database.this.state
}

# Capacity left in the container. These are how you tell whether an Autonomous
# Database will actually fit before you try to create it — provisioning fails on
# the create call, not at plan time, when the container is out of CPUs.
output "available_cpus" {
  description = "CPUs still unallocated in this container."
  value       = oci_database_autonomous_container_database.this.available_cpus
}

output "total_cpus" {
  description = "Total CPUs in this container."
  value       = oci_database_autonomous_container_database.this.total_cpus
}

output "largest_provisionable_autonomous_database_in_cpus" {
  description = "Largest single Autonomous Database this container can still fit, in CPUs."
  value       = oci_database_autonomous_container_database.this.largest_provisionable_autonomous_database_in_cpus
}

output "reclaimable_cpus" {
  description = "CPUs held by terminated databases, not yet returned to the pool."
  value       = oci_database_autonomous_container_database.this.reclaimable_cpus
}
