# ─────────────────────────────────────────────────────────────────────────────
# Database@Azure — Custom DNS, Scenario #2
# Network Anchor as a centralized DNS Hub for multiple Exadata environments.
#
# Source: "Custom DNS for Oracle AI Database@Azure" (A-Team) / Oracle docs
#         "DNS for Oracle AI Database@Azure".
#
# Two limits bound how far one hub stretches:
#
#   SAME-REGION ONLY. The hub and every VM cluster VCN it serves sit in the one
#   region configured below. The link is an LPG pair, and LPG peering does not
#   cross regions - there is no DRG or Remote Peering Connection here. Databases
#   spread across regions need one hub per region, each its own copy of this
#   configuration with its own Network Anchor and state.
#
#   LPG COUNT. Peering is 1:1, so every VM cluster VCN consumes one LPG on the
#   hub VCN. A VCN's LPG limit (10 by default) therefore caps how many VCNs one
#   hub can serve - see the hub_lpg_limit check below.
#
# Topology
# ────────
#                       ┌────────────────────────────┐
#   Azure private  ───▶ │  DNS Hub VCN (Network       │
#   resolver / VNets    │  Anchor)                    │
#                       │   • LISTENING endpoint  ◀───┼─── created here (anchor flag OFF)
#                       │   • FORWARDING endpoint ───▶┼─── anchor-created, not here
#                       │   • Existing per-env views  │
#                       │     ATTACHED (not created)  │
#                       └───────┬─────────────┬───────┘
#                       LPG 1:1 │             │ LPG 1:1
#                  ┌────────────▼──┐      ┌───▼────────────┐
#                  │ Exadata VCN   │      │ Exadata VCN    │
#                  │  (prod)       │      │  (nonprod)     │
#                  │  FORWARD ep ──┼──────┼─▶ hub listener │  egress: DB → Azure FQDN
#                  └───────────────┘      └────────────────┘
#
# This root module owns the HUB-side listening endpoint plus the attachment of
# each environment's EXISTING private view to the hub resolver.
#
# It does not create: views or zones (they must pre-date the VM cluster that was
# provisioned against them) or the hub forwarding endpoint (the Network Anchor
# creates that one).
#
# The reusable `exadata-dns-link` module wires each Exadata VCN to the hub
# (LPG pair + forwarding rule + NSG rules; routes are manual).
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 6.0.0"
    }
  }
}

provider "oci" {
  # Configure auth via env vars, config file, or instance principals.
  region = var.region
}

# Discover the Hub VCN's system resolver (where hub endpoints/views attach).
data "oci_core_vcn_dns_resolver_association" "hub" {
  vcn_id = var.hub_vcn_id
}

# Read the hub resolver to find the LISTENING endpoint the Network Anchor made.
data "oci_dns_resolver" "hub" {
  resolver_id = local.hub_resolver_id
  scope       = "PRIVATE"
}

locals {
  hub_resolver_id = coalesce(var.hub_resolver_id, data.oci_core_vcn_dns_resolver_association.hub.dns_resolver_id)

  # The hub's listening endpoint is created here, not by the Network Anchor —
  # see the resource below for why the anchor's own flag stays off. Its address
  # is what every spoke's forward rule points at.
  #
  # Only when create_hub_listening_endpoint is false (an anchor built with
  # isOracleDnsListeningEndpointEnabled on) is the address supplied explicitly or
  # discovered from the hub resolver's endpoint list — same pattern as
  # hub_resolver_id above.
  discovered_listening_ip = try(
    one([for e in data.oci_dns_resolver.hub.endpoints : e.listening_address if e.is_listening]),
    null,
  )
  hub_listening_ip = (
    var.create_hub_listening_endpoint
    ? oci_dns_resolver_endpoint.hub_listening[0].listening_address
    : coalesce(var.hub_listening_endpoint_ip, local.discovered_listening_ip)
  )

  # ── Hub resolver rules ─────────────────────────────────────────────────────
  #
  # The rule list is managed only once hub_resolver_forward_rules declares
  # something. While it is empty no rules block is emitted at all and the hub
  # resolver's rules stay untouched - which matters, because the Network Anchor
  # writes its OCI-to-Azure forwarding rules to this same resolver.
  manage_hub_rules = length(var.hub_resolver_forward_rules) > 0

  # The declared rules, ordered by map key so the list this configuration sends
  # is stable across runs. The key is local naming only; OCI never sees it.
  managed_hub_rules = [
    for k in sort(keys(var.hub_resolver_forward_rules)) : {
      action                    = var.hub_resolver_forward_rules[k].action
      source_endpoint_name      = var.hub_resolver_forward_rules[k].source_endpoint_name
      destination_addresses     = var.hub_resolver_forward_rules[k].destination_addresses
      qname_cover_conditions    = var.hub_resolver_forward_rules[k].qname_cover_conditions
      client_address_conditions = var.hub_resolver_forward_rules[k].client_address_conditions
    }
  ]

  # Fingerprints of the declared rules, used to recognise this configuration's
  # own entries when they come back from the live resolver on the second and
  # later runs - without this they would be appended again every apply.
  managed_hub_rule_keys = [for r in local.managed_hub_rules : jsonencode(r)]

  # What the resolver already carries, minus anything this configuration
  # declares. On the first run that is the anchor's forwarding rules; afterwards
  # it is the same set, because our own rules fingerprint-match and drop out.
  #
  # A rule DELETED from hub_resolver_forward_rules stops matching and is
  # therefore preserved as a foreign rule rather than removed - see the README.
  # Nothing here deletes a rule it did not just write.
  unmanaged_hub_rules = var.preserve_unmanaged_hub_resolver_rules ? [
    for j in sort(distinct([
      for r in data.oci_dns_resolver.hub.rules : jsonencode({
        action                    = r.action
        source_endpoint_name      = r.source_endpoint_name
        destination_addresses     = r.destination_addresses
        qname_cover_conditions    = r.qname_cover_conditions
        client_address_conditions = r.client_address_conditions
      })
    ])) : jsondecode(j) if !contains(local.managed_hub_rule_keys, j)
  ] : []

  # Preserved rules first, ours after. Sorted on both halves, so a reordering by
  # the service or the anchor does not show up as a permanent diff.
  hub_resolver_rules = local.manage_hub_rules ? concat(local.unmanaged_hub_rules, local.managed_hub_rules) : []

  # Every private view to attach to the hub resolver, flattened across all
  # environments and deduplicated. A VCN may carry several views, and two VM
  # cluster VCNs provisioned against the same view would otherwise attach it
  # twice — a duplicate the API rejects.
  attached_view_ids = distinct(flatten([for e in var.environments : e.view_ids]))
}

# ── Hub LISTENING endpoint — created HERE, not by the anchor ─────────────────
#
# The Network Anchor has a flag for each endpoint:
#
#   isOracleDnsListeningEndpointEnabled   -> listening endpoint  (Azure -> OCI)
#   isOracleDnsForwardingEndpointEnabled  -> forwarding endpoint (OCI -> Azure)
#
# ON THE HUB ANCHOR, THE LISTENING FLAG MUST BE FALSE.
#
# db-at-azure/modules/network-anchor exposes it as dns_listening_endpoint_enabled
# (default false) — leave it off for the anchor fronting this hub.
#
# Why: the anchor's listening endpoint belongs to the platform. It is provisioned
# in the subnet delegated to the anchor and serves that anchor's own DNS scope. A
# hub listener has to answer for EVERY environment's private views — the ones
# attached to the hub resolver below — from an address that stays put, because
# each spoke's FORWARD rule carries it as a literal destination and the hub-side
# security rules are written against its subnet. That endpoint is this
# configuration's to own, in a resolver subnet it is given. With both present the
# hub would carry two listeners on one resolver, on different addresses, only one
# of them wired up.
#
# The FORWARDING endpoint is still the anchor's, and is not created here: it is
# driven by isOracleDnsForwardingEndpointEnabled, and the Network Control Plane
# adds the forwarding rules declared on the anchor (dns_forwarding_rules) —
# declare the OCI-to-Azure domains there.
#
# Set create_hub_listening_endpoint = false only for a hub whose anchor was
# already built with the listening flag on; the address is then supplied or
# discovered, and nothing here writes to the platform's endpoint.
resource "oci_dns_resolver_endpoint" "hub_listening" {
  count = var.create_hub_listening_endpoint ? 1 : 0

  resolver_id   = local.hub_resolver_id
  name          = var.hub_listening_endpoint_name
  scope         = "PRIVATE"
  subnet_id     = var.hub_resolver_subnet_id
  is_listening  = true
  is_forwarding = false

  # Omitted = OCI assigns a free address from the subnet. Pin it to keep the
  # listener's IP stable across a rebuild: every spoke's forward rule and every
  # Azure DNS forwarding ruleset holds this address literally, so a new one means
  # editing all of them.
  listening_address = var.hub_listening_endpoint_ip

  lifecycle {
    precondition {
      condition     = var.hub_resolver_subnet_id != null
      error_message = "hub_resolver_subnet_id is required when create_hub_listening_endpoint is true - the listening endpoint needs a subnet in the hub VCN to sit in. Set it, or set create_hub_listening_endpoint = false if this hub's anchor was created with isOracleDnsListeningEndpointEnabled."
    }
  }
}

# ── Hub resolver subnet security list ────────────────────────────────────────
#
# Rules go into the DEFAULT security list you name, which is already attached to
# the hub resolver subnet - so nothing has to be attached afterwards, and nothing
# is attached to the resolver ENDPOINTS. That last part is why this is a security
# list and not an NSG: an NSG goes on the endpoint via nsg_ids, tying every
# rule's identity to an object this configuration replaces.
#
# Port 53 is opened BROADLY, from 0.0.0.0/0 - the same posture as the Network
# Anchor's own NSG. Everything that legitimately queries this listener is a
# resolver: each spoke's forwarding endpoint over its LPG, and Azure's private
# resolver. Enumerating those CIDRs bought nothing except a list to keep in step
# with every new spoke and every Azure-side change, and a silent outage whenever
# it fell behind. Reaching the endpoint still requires a route and a peering.
#
# ⚠ THE RULE SET IS AUTHORITATIVE. The OCI API replaces a security list's rules
#   wholesale, so what is declared here IS the list after apply - anything else
#   on it today is removed. Check before the first apply:
#
#     oci network security-list get --security-list-id <ocid> #       --query 'data.{ingress:"ingress-security-rules",egress:"egress-security-rules"}'
#
#   allow_all_egress (default true) re-states the egress-all rule a default list
#   normally carries, so leaving it on preserves that much.
resource "oci_core_default_security_list" "hub_resolver" {
  count = var.hub_resolver_security_list_id != null ? 1 : 0

  manage_default_resource_id = var.hub_resolver_security_list_id

  ingress_security_rules {
    protocol    = "17" # UDP
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    description = "DNS (UDP)"

    udp_options {
      min = 53
      max = 53
    }
  }

  ingress_security_rules {
    protocol    = "6" # TCP
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    description = "DNS (TCP)"

    tcp_options {
      min = 53
      max = 53
    }
  }

  # "all protocols to anywhere" - what a default security list ships with. Kept
  # unless you turn it off, because declaring rules here removes whatever is not
  # declared, and silently dropping egress would break outbound from every subnet
  # this list governs.
  dynamic "egress_security_rules" {
    for_each = var.allow_all_egress ? [1] : []
    content {
      protocol         = "all"
      destination      = "0.0.0.0/0"
      destination_type = "CIDR_BLOCK"
      description      = "All egress"
    }
  }
}

# ── Attach each environment's EXISTING private view to the hub resolver ──────
#
# The views and their zones are NOT created here. With Custom DNS, the private
# view and zone must exist *before* the Exadata VM cluster is provisioned — the
# cluster is created against that view, and the service then auto-populates it
# with the SCAN and VIP A records. Creating views here would mint empty ones
# with no database records while the populated view sat elsewhere.
#
# So each environment supplies the OCIDs of the views its VM cluster VCN was
# provisioned against, and this attaches every one of them to the hub resolver —
# letting the hub LISTENING endpoint answer Azure's queries for all of them.
# That is what makes the hub the single point of resolution: inbound answers
# come from these attached views, outbound leaves via each VM cluster VCN's own
# forward rule pointing back at this hub's listener (see modules/exadata-dns-link).
#
# NOTE: attached_views is authoritative — the OCI API replaces the whole list on
# update. Views attached to this resolver outside Terraform are detached on the
# next apply. The resolver's own default view is separate and is not affected.
resource "oci_dns_resolver" "hub" {
  resolver_id  = local.hub_resolver_id
  scope        = "PRIVATE"
  display_name = "dns-hub-resolver"

  # This update and the listening endpoint above both change the same resolver.
  # Ordering them keeps the two calls from colliding on one work request.
  depends_on = [oci_dns_resolver_endpoint.hub_listening]

  dynamic "attached_views" {
    for_each = local.attached_view_ids
    content {
      view_id = attached_views.value
    }
  }

  # Emitted only when hub_resolver_forward_rules declares something. With no
  # rules block the provider leaves the resolver's rules alone; with one, the
  # list below IS the resolver's rule list, which is why the anchor's rules are
  # read back and carried along in it.
  dynamic "rules" {
    for_each = local.hub_resolver_rules
    content {
      action                = rules.value.action
      source_endpoint_name  = rules.value.source_endpoint_name
      destination_addresses = rules.value.destination_addresses

      # Optional + Computed on the provider: an empty list would read as "leave
      # it to the service" and drift every plan, so send null instead.
      qname_cover_conditions    = length(rules.value.qname_cover_conditions) > 0 ? rules.value.qname_cover_conditions : null
      client_address_conditions = length(rules.value.client_address_conditions) > 0 ? rules.value.client_address_conditions : null
    }
  }

  lifecycle {
    # scope is Optional + ForceNew, and does not come back populated when this
    # resolver is imported - state ends up empty against a config saying
    # "PRIVATE", which plans a REPLACEMENT. Replacing is the dangerous path: the
    # destroy half clears the live resolver's attached views and rules, and the
    # create half restores only what this configuration declares. On the hub
    # that would drop the Network Anchor's own forwarding rules.
    #
    # The resolver is identified by resolver_id alone, so ignoring scope drift
    # costs nothing and removes the replacement trigger.
    ignore_changes = [scope]
  }
}

# Every environment puts one LPG on the hub VCN, and a VCN has a finite LPG
# limit - so that limit, not anything in this configuration, caps how many VM
# cluster VCNs one hub can serve. A check block rather than a variable
# validation: the limit is raisable by service request, so exceeding the default
# should warn at plan time, not block the apply.
check "hub_lpg_limit" {
  assert {
    condition = length(var.environments) <= var.hub_lpg_limit
    error_message = format(
      "%d environments need %d LPGs on the hub VCN, over the limit of %d. LPG peering is 1:1, so each VM cluster VCN consumes one. Raise the VCN's LPG limit by service request and set hub_lpg_limit to match, or split across a second hub.",
      length(var.environments),
      length(var.environments),
      var.hub_lpg_limit,
    )
  }
}

# A rule fires from a named endpoint on the resolver, and OCI rejects the whole
# update when that name matches nothing - taking the view attachments in the same
# call down with it. Endpoint names are discovered, not declared, so this is a
# check rather than a variable validation: it warns at plan time with the names
# that do exist, instead of failing the apply with an API error.
check "hub_rule_source_endpoints_exist" {
  assert {
    condition = alltrue([
      for k, r in var.hub_resolver_forward_rules :
      contains([for e in data.oci_dns_resolver.hub.endpoints : e.name if e.is_forwarding], r.source_endpoint_name)
    ])
    error_message = format(
      "hub_resolver_forward_rules names a source_endpoint_name that is not a FORWARDING endpoint on the hub resolver. Declared: %s. Forwarding endpoints found: %s. On a hub the forwarding endpoint is the Network Anchor's, from isOracleDnsForwardingEndpointEnabled - not the listening endpoint created here.",
      join(", ", [for k, r in var.hub_resolver_forward_rules : r.source_endpoint_name]),
      join(", ", [for e in data.oci_dns_resolver.hub.endpoints : e.name if e.is_forwarding]),
    )
  }
}

# ── Wire each Exadata VCN to the hub ─────────────────────────────────────────
module "link" {
  for_each = var.environments
  source   = "./modules/exadata-dns-link"

  compartment_id = var.compartment_id
  env_name       = each.key

  hub_vcn_id                = var.hub_vcn_id
  hub_listening_endpoint_ip = local.hub_listening_ip
  hub_resolver_subnet_cidr  = var.hub_resolver_subnet_cidr

  exadata_vcn_id               = each.value.vcn_id
  exadata_resolver_subnet_id   = each.value.resolver_subnet_id
  exadata_resolver_subnet_cidr = each.value.resolver_subnet_cidr

  exadata_resolver_security_list_id = each.value.resolver_security_list_id
  allow_all_egress                  = var.allow_all_egress

  # Null for both = create the LPG pair; set = reference an existing peering.
  existing_hub_lpg_id     = each.value.existing_hub_lpg_id
  existing_exadata_lpg_id = each.value.existing_exadata_lpg_id

  azure_forward_domains = var.azure_forward_domains
}
