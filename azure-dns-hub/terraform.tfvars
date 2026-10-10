# ── Fill in your OCIDs ───────────────────────────────────────────────────────

# Same-region only: the hub and every VM cluster VCN below live in this region.
region         = "us-ashburn-1"
compartment_id = "ocid1.compartment.oc1..xxxxxxxx"

# DNS Hub VCN (Network Anchor)
#
# The hub's anchor MUST be created with the listening endpoint OFF:
#
#   isOracleDnsListeningEndpointEnabled = false
#   (db-at-azure network-anchor module: dns_listening_endpoint_enabled = false,
#    which is its default — just leave it alone for the hub's anchor)
#
# The hub's listener is created here instead, in the resolver subnet below, so it
# answers from every environment's attached views on an address that stays put.
# The anchor keeps the FORWARDING endpoint (OCI → Azure) and its forwarding rules.
hub_vcn_id               = "ocid1.vcn.oc1.iad.aaaa_hub"
hub_resolver_subnet_id   = "ocid1.subnet.oc1.iad.aaaa_hub_resolver"
hub_resolver_subnet_cidr = "10.0.0.0/27"

# ── Resolver security lists ─────────────────────────────────────────────────
#
# Give the OCID of the DEFAULT security list on each resolver subnet - the hub's
# here, each environment's in the map below - and the DNS rules are written into
# it. It is already attached to the subnet, so there is nothing to wire up.
#
# Port 53 is opened broadly (0.0.0.0/0), the same as the Network Anchor's own
# NSG. Reaching a resolver endpoint still needs a route and a peering.
#
# ⚠ AUTHORITATIVE - the declared rules become the WHOLE list; anything else on it
#   today is removed. Check first:
#     oci network security-list get --security-list-id <ocid> #       --query 'data.{ingress:"ingress-security-rules",egress:"egress-security-rules"}'
#
# Omit an OCID to write that subnet's port-53 rules yourself.
hub_resolver_security_list_id = "ocid1.securitylist.oc1.iad.aaaa_hub_default"

# Re-states the "all protocols to 0.0.0.0/0" egress rule a default list normally
# ships with, since the rule set is replaced wholesale. Turn off only for lists
# you know carry no such rule.
# allow_all_egress = false

# Optional. Pins the listener's address inside hub_resolver_subnet_cidr; OCI picks
# a free one when omitted. Worth pinning — every spoke's forward rule and every
# Azure forwarding ruleset carries this IP literally.
# hub_listening_endpoint_ip = "10.0.0.5"

# Name of the listening endpoint created here. Unique within the hub resolver.
# hub_listening_endpoint_name = "dnsHubListener"

# Only for a hub whose anchor was already built with the listening flag ON: the
# platform's endpoint is then consumed (address discovered, or set above) and
# none is created here.
# create_hub_listening_endpoint = false

# Each environment below consumes one LPG on the hub VCN, so this caps how many
# VM cluster VCNs one hub serves. Raise it to match a limit increase granted by
# service request. Going over warns at plan time; it does not block the apply.
# hub_lpg_limit = 10

# Azure domains the databases must resolve through the hub
azure_forward_domains = ["azure.com", "windows.net", "database.azure.com"]

# ── Extra FORWARD rules on the HUB's own resolver ───────────────────────────
#
# Optional. For a domain the hub must send somewhere that is not Azure - on-prem
# or a partner DNS server. Not the per-spoke rules: those come from
# azure_forward_domains above.
#
# ⚠ Empty (the default) leaves the hub resolver's rules unmanaged, which is the
#   safe state - the Network Anchor writes its own rules there. Declaring one
#   rule makes Terraform authoritative over the whole list; the anchor's rules
#   are read and carried through so they survive. README §7.4 before you use it.
#
# hub_resolver_forward_rules = {
#   onprem = {
#     source_endpoint_name   = "anchorForwardingEndpoint"  # must already exist
#     destination_addresses  = ["192.168.10.53"]
#     qname_cover_conditions = ["corp.example.com"]
#   }
# }

# Route rules are NOT managed here - add the two LPG routes by hand after apply.
# See "Routing - manual, by design" in the README.

# One entry per Exadata environment — LPG peering is 1:1, so each gets its own pair.
#
# resolver_security_list_id is that subnet's DEFAULT security list; the DNS rules
# are written into it, replacing whatever else it holds.
#
# view_ids are the EXISTING private views belonging to that VM cluster VCN. They are
# referenced, never created — they have to pre-date the cluster so the service can
# auto-populate their zones with the SCAN and VIP records. All of them are attached
# to the hub resolver. A VCN may carry more than one; shared views are deduplicated.
environments = {
  prod = {
    vcn_id                    = "ocid1.vcn.oc1.iad.aaaa_prod"
    resolver_subnet_id        = "ocid1.subnet.oc1.iad.aaaa_prod_resolver"
    resolver_subnet_cidr      = "10.1.0.0/27"
    resolver_security_list_id = "ocid1.securitylist.oc1.iad.aaaa_prod_default"
    view_ids                  = ["ocid1.dnsview.oc1.iad.aaaa_prod_view"]

    # This VCN is ALREADY peered to the hub, so reference that pair rather than
    # creating one. Set both or neither. Omit to have the pair created.
    # existing_hub_lpg_id     = "ocid1.localpeeringgateway.oc1.iad.aaaa_hub_side"
    # existing_exadata_lpg_id = "ocid1.localpeeringgateway.oc1.iad.aaaa_prod_side"
  }
  nonprod = {
    vcn_id                    = "ocid1.vcn.oc1.iad.aaaa_nonprod"
    resolver_subnet_id        = "ocid1.subnet.oc1.iad.aaaa_nonprod_resolver"
    resolver_subnet_cidr      = "10.2.0.0/27"
    resolver_security_list_id = "ocid1.securitylist.oc1.iad.aaaa_nonprod_default"
    view_ids                  = ["ocid1.dnsview.oc1.iad.aaaa_nonprod_view"]
  }

  # A second prod VM cluster VCN: its own LPG pair and forward rule, sharing the
  # prod view above. The duplicate is deduplicated before attachment.
  # prod2 = {
  #   vcn_id               = "ocid1.vcn.oc1.iad.aaaa_prod2"
  #   resolver_subnet_id   = "ocid1.subnet.oc1.iad.aaaa_prod2_resolver"
  #   resolver_subnet_cidr = "10.3.0.0/27"
  #   resolver_security_list_id = "ocid1.securitylist.oc1.iad.aaaa_prod2_default"
  #   view_ids             = ["ocid1.dnsview.oc1.iad.aaaa_prod_view"]
  # }
}
