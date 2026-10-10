# All data resources are placed in this file.

# Optional: read the VCN's resolver so the forwarding endpoint can be located by
# name. Only used to build the attach command in outputs.tf - this template does
# not manage the resolver or its endpoints, which are created by other tooling.
#
# count, so the template works standalone when resolver_id is not supplied.
data "oci_dns_resolver" "this" {
  count       = var.resolver_id != null ? 1 : 0
  resolver_id = var.resolver_id
  scope       = "PRIVATE"
}
