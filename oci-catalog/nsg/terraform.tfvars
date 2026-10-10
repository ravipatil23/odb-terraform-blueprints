# ── Network Security Group ────────────────────────────────────────────────────
# Creates one NSG and its rules in an existing VCN.
#
# This does NOT attach the NSG to the VM cluster — that is a manual OCI CLI step.
# See README.md.

oci_region     = "us-ashburn-1"
compartment_id = "ocid1.compartment.oc1..xxxx"

# The VCN the VM cluster sits in.
vcn_id = "ocid1.vcn.oc1.iad.xxxx"

display_name = "exadata-db-access"

rules = {
  sqlnet_from_app = {
    direction   = "INGRESS"
    protocol    = "6" # TCP
    source      = "10.20.0.0/16"
    min_port    = 1521
    description = "SQL*Net from the application subnet"
  }

  ons_from_app = {
    direction   = "INGRESS"
    protocol    = "6"
    source      = "10.20.0.0/16"
    min_port    = 6200
    description = "ONS / FAN events"
  }

  ssh_from_bastion = {
    direction   = "INGRESS"
    protocol    = "6"
    source      = "10.20.5.0/24"
    min_port    = 22
    description = "SSH from bastion"
  }

  all_egress = {
    direction   = "EGRESS"
    protocol    = "all" # no ports with "all"
    destination = "0.0.0.0/0"
    description = "Unrestricted egress"
  }
}

# ── Attaching to the DNS forwarding endpoint (optional) ───────────────────────
# Set this and `terraform output -raw forwarder_attach_command` gives you a
# ready-to-run command attaching this NSG to the VCN's forwarding endpoint.
#
# The resolver and endpoint are created by other tooling, so this template does
# not manage them — nsg_ids lives on the endpoint, and Terraform can only set
# attributes of resources it owns. Hence a command rather than a resource.
#
#   oci dns resolver list --compartment-id <comp> --scope PRIVATE \
#     --query 'data[].{name:"display-name",id:id,vcn:"attached-vcn-id"}' --output table
#
# resolver_id = "ocid1.dnsresolver.oc1.iad.xxxx"
