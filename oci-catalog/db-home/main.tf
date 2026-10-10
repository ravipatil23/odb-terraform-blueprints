# ─────────────────────────────────────────────────────────────────────────────
# Database Home — standalone template
#
# Creates ONE DB Home on an existing Exadata VM cluster. Nothing else.
#
# Independent by design: it takes the VM cluster OCID as a plain input, so it
# does not need to know how that cluster was created. Fill in terraform.tfvars,
# apply, and take db_home_id from the outputs into the cdb template if you want
# a database on it.
# ─────────────────────────────────────────────────────────────────────────────

resource "oci_database_db_home" "this" {
  vm_cluster_id = var.vm_cluster_ocid
  source        = "VM_CLUSTER_NEW"
  display_name  = var.display_name
  db_version    = var.db_version
}
