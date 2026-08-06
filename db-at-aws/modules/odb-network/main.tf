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
