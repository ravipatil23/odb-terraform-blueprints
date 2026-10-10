terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.42.0" }
  }
}

resource "aws_odb_network_peering_connection" "this" {
  display_name    = var.display_name
  odb_network_id  = var.odb_network_id
  peer_network_id = var.peer_network_id

  region = var.region != "" ? var.region : null

  # peer_network_cidrs is update-only — the AWS API rejects it during initial create.
  # After the resource exists, uncomment the line below and re-apply to manage CIDRs.
  # peer_network_cidrs = var.peer_network_cidrs

  tags = var.tags

  lifecycle {
    # Delete protection, consistent with the other modules. A peering connection
    # is cheap to recreate, but tearing it down severs connectivity between the
    # ODB network and the peered VPC while it is rebuilt.
    #
    # This has to be a literal — prevent_destroy rejects variable references, so
    # unlike the GCP blueprint's deletion_protection input it cannot be flipped
    # from terraform.tfvars. To tear this down deliberately, delete this
    # lifecycle block, apply, then destroy.
    prevent_destroy = true
  }
}
