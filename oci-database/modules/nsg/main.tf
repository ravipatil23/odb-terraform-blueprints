# ─────────────────────────────────────────────────────────────────────────────
# nsg — a custom OCI Network Security Group in the VM cluster's VCN
#
# Exadata VM clusters sit in an OCI VCN whichever cloud fronts them, so the
# rules controlling who can reach the databases are OCI objects - even when the
# cluster itself was provisioned through db-at-aws / db-at-azure / db-at-gcp.
#
# Scope: creates the NSG and its rules. It does NOT attach the NSG - no
# vm-cluster resource on any cloud accepts an NSG argument. Attach it to the
# database VNICs or the subnet in OCI using the exported nsg_id.
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 7.11.0"
    }
  }
}

resource "oci_core_network_security_group" "this" {
  compartment_id = var.compartment_id
  vcn_id         = var.vcn_id
  display_name   = var.display_name
  freeform_tags  = var.freeform_tags
}

# One rule per map entry. The key names the rule in state, so keep it stable:
# renaming a key destroys and recreates that rule.
resource "oci_core_network_security_group_security_rule" "this" {
  for_each = var.rules

  network_security_group_id = oci_core_network_security_group.this.id
  direction                 = each.value.direction
  protocol                  = each.value.protocol
  description               = each.value.description
  stateless                 = each.value.stateless

  # source applies to INGRESS, destination to EGRESS. The unused side stays null
  # rather than empty, so the API is not told to match everything.
  source      = each.value.direction == "INGRESS" ? each.value.source : null
  source_type = each.value.direction == "INGRESS" ? each.value.source_type : null

  destination      = each.value.direction == "EGRESS" ? each.value.destination : null
  destination_type = each.value.direction == "EGRESS" ? each.value.destination_type : null

  # Port range applies to TCP ("6") and UDP ("17") only. Omitting min_port
  # leaves the protocol open on every port, which is what OCI means by no range.
  dynamic "tcp_options" {
    for_each = each.value.protocol == "6" && each.value.min_port != null ? [1] : []
    content {
      destination_port_range {
        min = each.value.min_port
        max = coalesce(each.value.max_port, each.value.min_port)
      }
    }
  }

  dynamic "udp_options" {
    for_each = each.value.protocol == "17" && each.value.min_port != null ? [1] : []
    content {
      destination_port_range {
        min = each.value.min_port
        max = coalesce(each.value.max_port, each.value.min_port)
      }
    }
  }

  dynamic "icmp_options" {
    for_each = each.value.protocol == "1" && each.value.icmp_type != null ? [1] : []
    content {
      type = each.value.icmp_type
      code = each.value.icmp_code
    }
  }
}
