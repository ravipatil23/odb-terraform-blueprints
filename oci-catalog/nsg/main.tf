# ─────────────────────────────────────────────────────────────────────────────
# Network Security Group — standalone template
#
# Creates ONE NSG and its rules in an existing VCN. Nothing else.
#
# Independent by design: it takes the compartment and VCN OCIDs as plain inputs.
#
# It does NOT attach the NSG to anything. No vm-cluster resource on AWS, Azure
# or GCP accepts an NSG argument, so attaching is a separate OCI CLI step
# against the cluster - see README.md.
# ─────────────────────────────────────────────────────────────────────────────

resource "oci_core_network_security_group" "this" {
  compartment_id = var.compartment_id
  vcn_id         = var.vcn_id
  display_name   = var.display_name
  freeform_tags  = var.freeform_tags
}

# OCI models each security rule as its own resource, so a set of rules means a
# set of resources. The rules map is the only iteration in this template - the
# NSG itself is a single plain resource.
resource "oci_core_network_security_group_security_rule" "this" {
  for_each = var.rules

  network_security_group_id = oci_core_network_security_group.this.id
  direction                 = each.value.direction
  protocol                  = each.value.protocol
  description               = each.value.description
  stateless                 = each.value.stateless

  source      = each.value.direction == "INGRESS" ? each.value.source : null
  source_type = each.value.direction == "INGRESS" ? each.value.source_type : null

  destination      = each.value.direction == "EGRESS" ? each.value.destination : null
  destination_type = each.value.direction == "EGRESS" ? each.value.destination_type : null

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
