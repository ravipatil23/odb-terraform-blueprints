# ─────────────────────────────────────────────────────────────────────────────
# Pluggable Database (PDB) — standalone template
#
# Creates ONE PDB inside an existing CDB. Nothing else.
#
# Independent by design: it takes the CDB OCID as a plain input. Create the CDB
# with the cdb template (or by hand), paste its id here, apply.
#
# The admin password comes from an environment variable, never tfvars:
#   export TF_VAR_pdb_admin_password='YourStr0ng#Pass'
# ─────────────────────────────────────────────────────────────────────────────

resource "oci_database_pluggable_database" "this" {
  container_database_id = var.container_database_id
  pdb_name              = var.pdb_name
  pdb_admin_password    = var.pdb_admin_password

  # The TDE wallet password defaults to the PDB admin password unless you set
  # one explicitly.
  tde_wallet_password = var.tde_wallet_password != "" ? var.tde_wallet_password : var.pdb_admin_password
}
