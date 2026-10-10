terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 6.0.0"
    }
  }
}

# Autonomous Container Database (ACD) on an Autonomous VM Cluster — the ADB-D
# equivalent of this blueprint's DB Home + CDB pair.
#
# It is a different resource from oci_database_database, not a flag on it, and
# the hierarchy is one level shallower: there is no Home. An ACD hosts
# Autonomous Databases (../autonomous-db), and unlike a CDB it takes no admin
# password — Oracle operates the container, so there is no SYS login to set.
resource "oci_database_autonomous_container_database" "this" {
  display_name = var.display_name
  patch_model  = var.patch_model

  # The Autonomous VM Cluster this container runs on.
  #
  # On Database@AWS this is the `ocid` output of db-at-aws's
  # autonomous-vm-cluster module — the OCI-side OCID, not the AWS id or ARN.
  # Note which field: cloud_autonomous_vm_cluster_id is the Exadata Cloud /
  # multicloud one. The similarly named autonomous_vm_cluster_id is for
  # Cloud@Customer and is not what a Database@AWS/GCP/Azure cluster hands you;
  # passing the OCID to that field fails on the create call, not at plan time.
  cloud_autonomous_vm_cluster_id = var.cloud_autonomous_vm_cluster_ocid

  # Nearly every remaining field is Optional + Computed, so an unset one adopts
  # whatever the service assigns and never diffs. That makes the "" -> null
  # conversion load-bearing: an empty string is not a valid value for any of
  # them, while null means "leave it to the service".
  compartment_id = var.compartment_id != "" ? var.compartment_id : null
  db_name        = var.db_name != "" ? var.db_name : null
  db_unique_name = var.db_unique_name != "" ? var.db_unique_name : null
  db_version     = var.db_version != "" ? var.db_version : null

  service_level_agreement_type = var.service_level_agreement_type != "" ? var.service_level_agreement_type : null
  distribution_affinity        = var.distribution_affinity != "" ? var.distribution_affinity : null
  net_services_architecture    = var.net_services_architecture != "" ? var.net_services_architecture : null
  version_preference           = var.version_preference != "" ? var.version_preference : null

  # Numbers and bools take null directly — there is no empty-string equivalent
  # for them, and 0 is a meaningful value for vm_failover_reservation (reserve
  # nothing), so a sentinel would swallow a real setting.
  db_split_threshold         = var.db_split_threshold
  vm_failover_reservation    = var.vm_failover_reservation
  is_dst_file_update_enabled = var.is_dst_file_update_enabled

  # Customer-managed TDE keys. Both or neither: a key without its vault is not
  # resolvable. Omitted entirely, the container uses Oracle-managed keys.
  kms_key_id = var.kms_key_id != "" ? var.kms_key_id : null
  vault_id   = var.vault_id != "" ? var.vault_id : null

  # Backup retention for the container. Sent only when asked for, so that an
  # unset value keeps the service default rather than pinning one here.
  dynamic "backup_config" {
    for_each = var.backup_recovery_window_in_days != null ? [1] : []
    content {
      recovery_window_in_days = var.backup_recovery_window_in_days
    }
  }

  dynamic "customer_contacts" {
    for_each = var.customer_contacts
    content {
      email = customer_contacts.value
    }
  }

  dynamic "maintenance_window_details" {
    for_each = var.maintenance_window != null ? [var.maintenance_window] : []
    content {
      preference                       = maintenance_window_details.value.preference != "" ? maintenance_window_details.value.preference : null
      patching_mode                    = maintenance_window_details.value.patching_mode != "" ? maintenance_window_details.value.patching_mode : null
      is_monthly_patching_enabled      = maintenance_window_details.value.is_monthly_patching_enabled
      lead_time_in_weeks               = maintenance_window_details.value.lead_time_in_weeks
      hours_of_day                     = length(maintenance_window_details.value.hours_of_day) > 0 ? maintenance_window_details.value.hours_of_day : null
      weeks_of_month                   = length(maintenance_window_details.value.weeks_of_month) > 0 ? maintenance_window_details.value.weeks_of_month : null
      custom_action_timeout_in_mins    = maintenance_window_details.value.custom_action_timeout_in_mins
      is_custom_action_timeout_enabled = maintenance_window_details.value.is_custom_action_timeout_enabled

      dynamic "days_of_week" {
        for_each = maintenance_window_details.value.days_of_week
        content {
          name = days_of_week.value
        }
      }

      dynamic "months" {
        for_each = maintenance_window_details.value.months
        content {
          name = months.value
        }
      }
    }
  }

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    # Oracle patches an Autonomous container on its own schedule, which moves
    # db_version out from under the config. Without this guard every plan after
    # a maintenance run wants to push the pinned version back and recreate the
    # container — taking every Autonomous Database inside it along.
    ignore_changes = [db_version]

    # A precondition rather than a root check block, because a check only warns
    # and this is a certain failure. Without a cluster OCID the create call is
    # rejected, and an ACD create is not a cheap thing to discover late.
    precondition {
      condition     = var.cloud_autonomous_vm_cluster_ocid != ""
      error_message = "No Autonomous VM Cluster OCID for this container: set the top-level autonomous_vm_cluster_ocid, or cloud_autonomous_vm_cluster_ocid on this entry. It is the `ocid` output of db-at-aws's autonomous-vm-cluster module, not the AWS id or ARN."
    }

    # A key without its vault is not resolvable, and a vault without a key does
    # nothing. Either both or neither.
    precondition {
      condition     = (var.kms_key_id != "") == (var.vault_id != "")
      error_message = "Set kms_key_id and vault_id together, or neither. A customer-managed TDE key cannot be resolved without the vault that holds it."
    }
  }
}
