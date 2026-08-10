terraform {
  required_providers {
    azapi = { source = "Azure/azapi", version = ">= 2.0.0" }
  }
}

# Oracle.Database/networkAnchors — bridges an Azure delegated subnet to OCI.
# Provisioned through azapi because azurerm has no native resource for it, which
# is why this module declares a different provider from every other module here.
#
# Needs an existing Resource Anchor and a subnet delegated to
# Oracle.Database/networkAttachment. Both are wired from the root.
resource "azapi_resource" "this" {
  type      = "Oracle.Database/networkAnchors@2025-09-01"
  name      = var.name
  parent_id = "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}"
  location  = var.location
  tags      = var.tags

  body = {
    # zones sits at the body level, not under properties — it is the AZ the Base
    # Database will reside in.
    zones = var.zones

    properties = merge(
      {
        resourceAnchorId                     = var.resource_anchor_id
        subnetId                             = var.subnet_id
        isOracleDnsListeningEndpointEnabled  = var.dns_listening_endpoint_enabled
        isOracleDnsForwardingEndpointEnabled = var.dns_forwarding_endpoint_enabled
        isOracleToAzureDnsZoneSyncEnabled    = var.dns_zone_sync_enabled
      },
      # Optional fields are omitted rather than sent empty, so the API applies its
      # own defaults instead of being told to use a blank value.
      var.oci_vcn_dns_label != "" ? { ociVcnDnsLabel = var.oci_vcn_dns_label } : {},
      var.oci_backup_cidr_block != "" ? { ociBackupCidrBlock = var.oci_backup_cidr_block } : {},
      var.dns_listening_allowed_cidrs != "" ? { dnsListeningEndpointAllowedCidrs = var.dns_listening_allowed_cidrs } : {},
      length(var.dns_forwarding_rules) > 0 ? {
        dnsForwardingRules = [for r in var.dns_forwarding_rules : {
          domainNames         = r.domain_names
          forwardingIpAddress = r.forwarding_ip_address
        }]
      } : {},
    )
  }

  lifecycle {
    # Delete protection. The anchor is the path between the delegated subnet and
    # OCI; destroying it cuts connectivity for anything using it.
    #
    # This has to be a literal — prevent_destroy rejects variable references. To
    # tear it down deliberately, delete this lifecycle block, apply, then destroy.
    prevent_destroy = true
  }
}
