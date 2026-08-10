terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = ">= 4.9.0" }
  }
}

# Oracle.Database/resourceAnchors — maps an Azure resource group to an OCI
# compartment. This is the foundational prerequisite for Database@Azure: the
# Network Anchor, Exadata infrastructure and VM clusters all need it to exist
# first. Nothing takes its ID as an argument, so the ordering is expressed with
# depends_on in the root rather than by wiring.
#
# location and linked_compartment_id are assigned by the service — the anchor
# inherits its region from the resource group, so neither is settable.
resource "azurerm_oracle_resource_anchor" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  tags                = var.tags

  timeouts {
    create = "60m"
    delete = "60m"
  }

  lifecycle {
    # Delete protection. Destroying the anchor unlinks the OCI compartment that
    # every other Database@Azure resource in this resource group hangs off.
    #
    # This has to be a literal — prevent_destroy rejects variable references. To
    # tear it down deliberately, delete this lifecycle block, apply, then destroy.
    prevent_destroy = true
  }
}
