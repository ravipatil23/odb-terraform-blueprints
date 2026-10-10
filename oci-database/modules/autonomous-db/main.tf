terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 7.11.0"
    }
  }
}

# Autonomous Database, Dedicated (ADB-D) — an Autonomous Database inside an
# Autonomous Container Database. This is the ADB-D equivalent of a PDB.
#
# Not to be confused with the autonomous-db modules in db-at-azure / db-at-gcp:
# those build Autonomous Database *Serverless* through their native providers,
# where Oracle runs the fleet and there is no cluster or container underneath.
# Here the database is pinned to a container, therefore to an Autonomous VM
# Cluster, therefore to the ODB network the cluster sits on. That is also why
# this module takes no subnet_id / nsg_ids / private_endpoint_label: those are
# Serverless private-endpoint fields. An ADB-D inherits its networking from the
# cluster, and reachability is governed by the NSGs in ../nsg.
resource "oci_database_autonomous_database" "this" {
  compartment_id = var.compartment_id
  db_name        = var.db_name

  is_dedicated                     = true
  autonomous_container_database_id = var.autonomous_container_database_id

  # ── Admin password ──────────────────────────────────────────────────────────
  # Two ways in, and they are mutually exclusive:
  #
  #   secret_id       an OCI Vault secret holding the password. The resource
  #                   stores the *reference*, so the password itself never
  #                   enters Terraform state. Prefer this.
  #   admin_password  the literal value. It goes into state in cleartext, where
  #                   `sensitive` hides it from CLI output but not from the
  #                   state file or anyone who can read the backend.
  #
  # Both fields are Optional + Computed, so the unused one must be null — "" is
  # not a valid password and would be sent as a real (invalid) value. The root
  # rejects setting both for one database at plan time.
  secret_id             = var.admin_password_secret_id != "" ? var.admin_password_secret_id : null
  secret_version_number = var.admin_password_secret_id != "" ? var.admin_password_secret_version_number : null
  admin_password        = var.admin_password_secret_id == "" && var.admin_password != "" ? var.admin_password : null

  # ── Sizing ─────────────────────────────────────────────────────────────────
  # ECPU is the current model: set compute_model = "ECPU" with compute_count.
  # cpu_core_count is the older OCPU model. Send one, not both — each is
  # Optional + Computed, so the unused one must be null to stay quiet.
  compute_model            = var.compute_model != "" ? var.compute_model : null
  compute_count            = var.compute_count
  cpu_core_count           = var.cpu_core_count
  data_storage_size_in_tbs = var.data_storage_size_in_tbs

  is_auto_scaling_enabled             = var.is_auto_scaling_enabled
  is_auto_scaling_for_storage_enabled = var.is_auto_scaling_for_storage_enabled

  # ── Shape and behaviour ────────────────────────────────────────────────────
  display_name                         = var.display_name != "" ? var.display_name : null
  db_workload                          = var.db_workload != "" ? var.db_workload : null
  db_version                           = var.db_version != "" ? var.db_version : null
  database_edition                     = var.database_edition != "" ? var.database_edition : null
  license_model                        = var.license_model != "" ? var.license_model : null
  character_set                        = var.character_set != "" ? var.character_set : null
  ncharacter_set                       = var.ncharacter_set != "" ? var.ncharacter_set : null
  in_memory_percentage                 = var.in_memory_percentage
  is_mtls_connection_required          = var.is_mtls_connection_required
  autonomous_maintenance_schedule_type = var.autonomous_maintenance_schedule_type != "" ? var.autonomous_maintenance_schedule_type : null

  # Customer-managed TDE keys, independent of the container's.
  kms_key_id = var.kms_key_id != "" ? var.kms_key_id : null
  vault_id   = var.vault_id != "" ? var.vault_id : null

  dynamic "customer_contacts" {
    for_each = var.customer_contacts
    content {
      email = customer_contacts.value
    }
  }

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    # admin_password: a rotation performed outside Terraform (or the service
    # reporting nothing back for a secret-backed database) must not read as
    # drift that rewrites the password on the next apply.
    #
    # db_version: Oracle patches an Autonomous Database on its own schedule,
    # exactly as it does the container.
    ignore_changes = [admin_password, db_version]

    # Preconditions, not a root check block: a check only warns, and both of
    # these are certain apply failures rather than things to think about. A
    # precondition fails the plan, before anything is created.
    #
    # XOR on the two routes. Neither set leaves the database with no password at
    # all; both set means the provider takes the secret and ignores the literal,
    # which leaves a cleartext password sitting in state having achieved nothing.
    precondition {
      condition     = (var.admin_password_secret_id != "") != (var.admin_password != "")
      error_message = "Supply exactly one of admin_password_secret_id (preferred) or admin_password for this Autonomous Database — not both, not neither."
    }

    precondition {
      condition     = var.compartment_id != ""
      error_message = "An Autonomous Database needs a compartment OCID: set it on the database entry, on its container, or as the top-level compartment_id. Unlike the container, it is not inherited from the cluster."
    }

    # One sizing model at a time. compute_count is ECPU, cpu_core_count is OCPU;
    # sending both asks the service for two different shapes at once.
    precondition {
      condition     = !(var.compute_count != null && var.cpu_core_count != null)
      error_message = "Set compute_count (with compute_model = \"ECPU\") or cpu_core_count (with compute_model = \"OCPU\"), not both."
    }

    precondition {
      condition     = (var.kms_key_id != "") == (var.vault_id != "")
      error_message = "Set kms_key_id and vault_id together, or neither. A customer-managed TDE key cannot be resolved without the vault that holds it."
    }
  }
}
