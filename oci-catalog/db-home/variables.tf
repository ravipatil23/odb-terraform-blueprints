variable "oci_region" {
  type        = string
  description = "OCI region of the VM cluster, e.g. \"us-ashburn-1\"."
}

variable "vm_cluster_ocid" {
  type        = string
  description = "OCID of the existing Exadata VM cluster this home is created on (ocid1.cloudvmcluster...). Must be visible to the OCI credentials Terraform runs with - verify first with: oci db cloud-vm-cluster get --cloud-vm-cluster-id <ocid>"

  validation {
    condition     = can(regex("^ocid1\\.(cloudvmcluster|vmcluster)\\.", var.vm_cluster_ocid))
    error_message = "Expected a VM cluster OCID starting ocid1.cloudvmcluster (Exadata Cloud Service) or ocid1.vmcluster (Cloud@Customer)."
  }
}

variable "display_name" {
  type        = string
  description = "Display name for the DB Home."
}

variable "db_version" {
  type        = string
  description = "Oracle version for this home, e.g. \"19.28.0.0.0\" or \"23.0.0.0\". Must be supported by the cluster's Grid Infrastructure."
}
