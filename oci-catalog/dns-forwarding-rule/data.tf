# All data resources are placed in this file.

# Read the resolver so the endpoint name can be checked before apply (see the
# check block in main.tf), and so the rules it already carries are visible in
# the plan and captured by the rules_before_apply output.
data "oci_dns_resolver" "this" {
  resolver_id = var.resolver_id
  scope       = "PRIVATE"
}
