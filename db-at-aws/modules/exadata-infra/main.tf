terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.15.0" }
  }
}

resource "aws_odb_cloud_exadata_infrastructure" "this" {
  display_name         = var.display_name
  shape                = var.shape
  compute_count        = var.compute_count
  storage_count        = var.storage_count
  availability_zone_id = var.availability_zone_id

  availability_zone    = var.availability_zone != "" ? var.availability_zone : null
  region               = var.region != "" ? var.region : null
  database_server_type = var.database_server_type != "" ? var.database_server_type : null
  storage_server_type  = var.storage_server_type != "" ? var.storage_server_type : null

  customer_contacts_to_send_to_oci = length(var.customer_contacts) > 0 ? [for e in var.customer_contacts : { email = e }] : null

  maintenance_window {
    preference                       = var.mw_preference
    patching_mode                    = var.mw_patching_mode
    is_custom_action_timeout_enabled = var.mw_is_custom_action_timeout_enabled
    custom_action_timeout_in_mins    = var.mw_custom_action_timeout_in_mins
    lead_time_in_weeks               = var.mw_lead_time_in_weeks > 0 ? var.mw_lead_time_in_weeks : null
    days_of_week                     = length(var.mw_days_of_week) > 0 ? [for d in var.mw_days_of_week : { name = d }] : null
    months                           = length(var.mw_months) > 0 ? [for m in var.mw_months : { name = m }] : null
    hours_of_day                     = length(var.mw_hours_of_day) > 0 ? var.mw_hours_of_day : null
    weeks_of_month                   = length(var.mw_weeks_of_month) > 0 ? var.mw_weeks_of_month : null
  }

  tags = var.tags

  lifecycle {
    # Delete protection. Exadata infrastructure takes hours to provision and is
    # billed as dedicated hardware, so an accidental destroy is expensive twice
    # over.
    #
    # This has to be a literal — prevent_destroy rejects variable references, so
    # unlike the GCP blueprint's deletion_protection input it cannot be flipped
    # from terraform.tfvars. To tear this down deliberately, delete this
    # lifecycle block, apply, then destroy.
    prevent_destroy = true
  }
}
