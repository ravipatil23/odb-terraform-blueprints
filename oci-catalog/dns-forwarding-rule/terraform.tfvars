# ── DNS forwarding rules ──────────────────────────────────────────────────────
# Adds FORWARD rules to an existing VCN resolver, via a forwarding endpoint that
# already exists.
#
# ⚠ This list REPLACES every rule on the resolver — the API writes the rules
# array as a unit and does not append. Check what is there first and bring across
# anything you need to keep:
#   oci dns resolver get --resolver-id <ocid> --scope PRIVATE --query 'data.rules'

oci_region = "us-ashburn-1"

# The resolver owned by the VCN the VM cluster sits in. Find it with:
#   oci dns resolver list --compartment-id <comp> --scope PRIVATE \
#     --query 'data[].{name:"display-name",id:id,vcn:"attached-vcn-id"}' --output table
#
# Must be in the region set above, and visible to the credentials Terraform uses.
resolver_id = "ocid1.dnsresolver.oc1.iad.xxxx"

# The forwarding endpoint the rules send queries out of. Alphanumeric only —
# OCI rejects hyphens and underscores here.
source_endpoint_name = "prodOnpremFwd"

# ── Does the endpoint already exist, or should this template create it? ───────
#
# false (default) — it exists, made by other tooling. This template only names
#   it, and a check block confirms it is on the resolver before apply. An NSG
#   cannot be attached from here: nsg_ids is an attribute of the endpoint, and
#   Terraform only sets attributes of resources it manages. Use the command from
#   the nsg template's forwarder_attach_command output instead.
#
# true — this template creates it, and therefore owns it. That makes
#   forwarder_nsg_ids work: the NSG is attached at creation, no CLI step.
#   Feed it nsg_id from the nsg template.
#
# create_forwarder    = true
# forwarder_subnet_id = "ocid1.subnet.oc1.iad.xxxx"   # required when creating
# forwarder_nsg_ids   = ["ocid1.networksecuritygroup.oc1.iad.xxxx"]
#
# Optional — auto-assigned from the subnet when omitted.
# forwarder_forwarding_address = "10.0.1.12"

# First match wins — most specific domains first.
rules = [
  {
    qname_cover_conditions = ["corp.example.com", "ad.example.com"]
    destination_addresses  = ["10.1.1.10", "10.1.1.11"] # on-prem resolvers
  },
  {
    qname_cover_conditions = ["partner.example.net"]
    destination_addresses  = ["10.2.5.10"]

    # Restrict to queries from these client CIDRs; omit for all clients.
    # client_address_conditions = ["10.0.1.0/24"]
  },
]
