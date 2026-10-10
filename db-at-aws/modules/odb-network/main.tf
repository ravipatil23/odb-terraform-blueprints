terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.15.0"
    }
  }
}

resource "aws_odb_network" "this" {
  display_name         = var.display_name
  availability_zone_id = var.availability_zone_id
  client_subnet_cidr   = var.client_subnet_cidr
  backup_subnet_cidr   = var.backup_subnet_cidr
  s3_access            = var.s3_access
  zero_etl_access      = var.zero_etl_access

  # sts_access and kms_access are Optional + Computed: omitted, each adopts the
  # value the service assigned and does not diff. Sending "" would not be a
  # valid status, so an unset field must become null rather than an empty string.
  #
  # terraform fmt aligns each run of arguments between comments separately, so
  # the comments below are load-bearing: they are what keeps these two blocks at
  # their own widths instead of widening everything to the longest key.
  sts_access = var.sts_access != "" ? var.sts_access : null
  kms_access = var.kms_access != "" ? var.kms_access : null

  # Endpoint policies. Each is only meaningful alongside its access flag.
  s3_policy_document  = var.s3_policy_document != "" ? var.s3_policy_document : null
  sts_policy_document = var.sts_policy_document != "" ? var.sts_policy_document : null
  kms_policy_document = var.kms_policy_document != "" ? var.kms_policy_document : null

  cross_region_s3_restore_sources_access = length(var.cross_region_s3_restore_sources_access) > 0 ? var.cross_region_s3_restore_sources_access : null

  availability_zone           = var.availability_zone != "" ? var.availability_zone : null
  region                      = var.region != "" ? var.region : null
  custom_domain_name          = var.custom_domain_name != "" ? var.custom_domain_name : null
  default_dns_prefix          = var.custom_domain_name == "" && var.default_dns_prefix != "" ? var.default_dns_prefix : null
  delete_associated_resources = var.delete_associated_resources

  tags = var.tags

  timeouts {
    create = "12h"
    update = "2h"
    delete = "8h"
  }

  lifecycle {
    # Delete protection. Every other resource in this blueprint hangs off the ODB
    # Network, so destroying it takes the whole stack with it.
    #
    # This has to be a literal — prevent_destroy rejects variable references, so
    # unlike the GCP blueprint's deletion_protection input it cannot be flipped
    # from terraform.tfvars. To tear this down deliberately, delete this
    # lifecycle block, apply, then destroy.
    prevent_destroy = true
  }
}
