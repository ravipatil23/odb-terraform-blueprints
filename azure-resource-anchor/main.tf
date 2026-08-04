# Oracle Database@Azure — Resource Anchor(s)
#
# Provisions the Oracle.Database/resourceAnchors resource via the native azurerm
# provider. A Resource Anchor maps an Azure resource group to an OCI compartment and
# is the FOUNDATIONAL prerequisite for everything else on Database@Azure — the
# Network Anchor, Exadata infrastructure and VM clusters all depend on it existing.
#
# location and linked_compartment_id are assigned by the service (computed) — you do
# not set them; the anchor inherits its region from the resource group.
#
# Fill in terraform.tfvars and run. Add a map entry to create more anchors.

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.9.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

resource "azurerm_oracle_resource_anchor" "this" {
  for_each = var.resource_anchors

  name                = each.value.name
  resource_group_name = each.value.resource_group_name
  tags                = each.value.tags

  timeouts {
    create = "60m"
    delete = "60m"
  }
}
