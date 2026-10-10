# ─────────────────────────────────────────────────────────────────────────────
# exadata-dns-link — wire one Exadata VCN to the central DNS Hub VCN
#
# Implements the per-spoke wiring from:
#   "Custom DNS for Oracle AI Database@Azure" — Scenario #2:
#   Multiple Database@Azure Environments With Custom DNS Using the
#   Network Anchor as a DNS Hub.
#
# For ONE Exadata environment (e.g. prod or nonprod) this creates:
#   1. A 1:1 Local Peering Gateway (LPG) pair between the Exadata VCN and
#      the DNS Hub VCN  (LPG peering is strictly 1:1, so each environment
#      gets its own pair).
#   2. A FORWARDING DNS resolver endpoint on the Exadata VCN resolver.
#   3. A resolver FORWARD rule that sends the configured Azure domains to
#      the DNS Hub's LISTENING endpoint, so databases can resolve Azure
#      FQDNs (egress: Exadata → Azure).
#   4. NSG ingress rules opening DNS (UDP/TCP 53) across the peering.
#   5. Optional route rules (default route table) on both VCNs so the
#      resolver subnets can reach each other over the LPG pair.
#
# Ingress resolution (Azure → OCI private zones) is handled by the Hub's
# LISTENING endpoint and the private views/zones, created in the root module.
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 6.0.0"
    }
  }
}

locals {
  prefix = "${var.env_name}-dnshub"

  # The VCN's default (system) resolver. Supply it explicitly, or let the
  # module discover it from the VCN via the association data source.
  exadata_resolver_id = coalesce(
    var.exadata_resolver_id,
    data.oci_core_vcn_dns_resolver_association.exadata.dns_resolver_id,
  )

  # Create the LPG pair only when an existing peering was not supplied. OCI
  # permits exactly ONE peering between any two VCNs, so if these VCNs are
  # already joined - by another stack, by the platform, or by hand - creating a
  # second pair fails at ConnectLocalPeeringGateways with "A peering with VCN
  # ... has already been established".
  #
  # That failure is worse than it looks: CreateLocalPeeringGateway succeeds and
  # only the connect call fails, so each attempt leaves TWO orphaned gateways
  # behind - present, unpeered, and counting against the 10-LPG limit on both
  # VCNs. Retrying strands two more. Referencing the existing pair avoids the
  # create entirely.
  create_lpgs = var.existing_hub_lpg_id == null

  hub_lpg_id     = local.create_lpgs ? oci_core_local_peering_gateway.hub[0].id : var.existing_hub_lpg_id
  exadata_lpg_id = local.create_lpgs ? oci_core_local_peering_gateway.exadata[0].id : var.existing_exadata_lpg_id

}

# Discover the Exadata VCN's system resolver when not supplied explicitly.
data "oci_core_vcn_dns_resolver_association" "exadata" {
  vcn_id = var.exadata_vcn_id
}

# ── 1:1 Local Peering Gateway pair  (Exadata VCN ⇄ DNS Hub VCN) ──────────────
#
# Skipped entirely when existing_hub_lpg_id / existing_exadata_lpg_id are set -
# see the create_lpgs local above.

# Hub side — acceptor, created first (no peer_id).
resource "oci_core_local_peering_gateway" "hub" {
  count          = local.create_lpgs ? 1 : 0
  compartment_id = var.compartment_id
  vcn_id         = var.hub_vcn_id
  display_name   = "${local.prefix}-hub-lpg"
}

# Exadata side — requester, establishes the peering toward the hub LPG.
resource "oci_core_local_peering_gateway" "exadata" {
  count          = local.create_lpgs ? 1 : 0
  compartment_id = var.compartment_id
  vcn_id         = var.exadata_vcn_id
  display_name   = "${local.prefix}-exadata-lpg"
  peer_id        = oci_core_local_peering_gateway.hub[0].id
}

# ── FORWARDING endpoint on the Exadata VCN resolver ──────────────────────────
# Source of egress queries from the databases toward the Hub listener.

resource "oci_dns_resolver_endpoint" "exadata_forward" {
  resolver_id   = local.exadata_resolver_id
  name          = "${var.env_name}ExadataFwd"
  scope         = "PRIVATE"
  subnet_id     = var.exadata_resolver_subnet_id
  is_forwarding = true
  is_listening  = false

  # forwarding_address is auto-assigned from the subnet when omitted.
}

# ── FORWARD rule: Azure domains → Hub LISTENING endpoint ─────────────────────
# Manages the Exadata VCN's existing system resolver to add the rule.
# qname_cover_conditions lists the Azure domains that must resolve via the hub.

resource "oci_dns_resolver" "exadata" {
  resolver_id  = local.exadata_resolver_id
  scope        = "PRIVATE"
  display_name = "${var.env_name}-exadata-resolver"

  rules {
    action                 = "FORWARD"
    source_endpoint_name   = oci_dns_resolver_endpoint.exadata_forward.name
    destination_addresses  = [var.hub_listening_endpoint_ip]
    qname_cover_conditions = var.azure_forward_domains
  }

  lifecycle {
    # scope is Optional + ForceNew and does not come back populated on import,
    # so state ends up empty against a config saying "PRIVATE" and Terraform
    # plans a REPLACEMENT. The destroy half of that clears this resolver's rules
    # on the live VCN. resolver_id identifies it on its own, so ignoring scope
    # drift removes the trigger at no cost. See the root module for detail.
    ignore_changes = [scope]
  }
}

# ── DNS security (UDP/TCP 53) across the peering ─────────────────────────────
#
# THIS MODULE WRITES NOTHING TO THE HUB SIDE. The Network Anchor's own NSG is the
# anchor's to manage, and the hub resolver subnet's list is the root module's.
#
# Here: the DEFAULT security list already attached to this environment's resolver
# subnet, named as exadata_resolver_security_list_id. Nothing is attached to the
# resolver endpoint itself - an NSG would have to be, via nsg_ids, tying every
# rule to an object this module replaces.
#
# ⚠ AUTHORITATIVE: what is declared below IS the list after apply. See the root
#   module and README §8.
resource "oci_core_default_security_list" "exadata_resolver" {
  count = var.exadata_resolver_security_list_id != null ? 1 : 0

  manage_default_resource_id = var.exadata_resolver_security_list_id

  # Egress 53 is the rule this side actually needs: the forwarding endpoint is
  # what initiates, sending the Azure domains up to the hub listener. Broad, like
  # the hub side - see the root module. Redundant while allow_all_egress is on,
  # and the one that matters once it is off.
  egress_security_rules {
    protocol         = "17" # UDP
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    description      = "DNS (UDP)"

    udp_options {
      min = 53
      max = 53
    }
  }

  egress_security_rules {
    protocol         = "6" # TCP
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    description      = "DNS (TCP)"

    tcp_options {
      min = 53
      max = 53
    }
  }

  dynamic "egress_security_rules" {
    for_each = var.allow_all_egress ? [1] : []
    content {
      protocol         = "all"
      destination      = "0.0.0.0/0"
      destination_type = "CIDR_BLOCK"
      description      = "All egress"
    }
  }

  # Ingress on 53. The egress rules are stateful, so answers come back without
  # this - it is here for a hub that queries this VCN's resolver directly rather
  # than only answering it.
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
}

# ── Routing over the LPG pair ────────────────────────────────────────────────
# DNS packets must route between the two resolver subnets over the LPG pair, but
# this module does NOT manage route tables. Add the two rules by hand after apply
# - see "Routing" in the README for the exact values and CLI commands.
#
# It used to offer to manage each VCN's default route table behind a
# manage_route_tables flag. That was removed: oci_core_default_route_table with
# manage_default_resource_id makes Terraform authoritative over the table, so any
# rule not in the config is deleted on the next apply. On an Exadata VCN those
# rules belong to Oracle, are not reliably enumerable, and can be added after you
# import - so a later apply would silently remove live routes.
#
# The LPG OCIDs you need are outputs of this module.

