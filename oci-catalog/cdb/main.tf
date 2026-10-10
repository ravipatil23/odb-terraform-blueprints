# ─────────────────────────────────────────────────────────────────────────────
# Container Database (CDB) — standalone template
#
# Creates ONE CDB in an existing DB Home. Nothing else.
#
# Independent by design: it takes the DB Home OCID as a plain input. Create the
# home with the db-home template (or by hand), paste its id here, apply.
#
# The admin password comes from an environment variable, never tfvars:
#   export TF_VAR_admin_password='YourStr0ng#Pass'
# ─────────────────────────────────────────────────────────────────────────────

resource "oci_database_database" "this" {
  db_home_id = var.db_home_id
  source     = "NONE"

  database {
    db_name        = var.db_name
    admin_password = var.admin_password
    character_set  = var.character_set
    ncharacter_set = var.ncharacter_set

    # Optional — omitted (null) unless set.
    pdb_name       = var.initial_pdb_name != "" ? var.initial_pdb_name : null
    db_unique_name = var.db_unique_name != "" ? var.db_unique_name : null
    sid_prefix     = var.sid_prefix != "" ? var.sid_prefix : null

    db_backup_config {
      auto_backup_enabled     = var.auto_backup_enabled
      auto_backup_window      = var.auto_backup_enabled ? var.auto_backup_window : null
      recovery_window_in_days = var.auto_backup_enabled ? var.recovery_window_in_days : null
    }
  }

  lifecycle {
    # The password is not readable back from the API, and `source` is only
    # meaningful at create time — both would otherwise show as perpetual drift.
    # Rotate the password through database tooling, not Terraform.
    ignore_changes = [database[0].admin_password, source]
  }
}
