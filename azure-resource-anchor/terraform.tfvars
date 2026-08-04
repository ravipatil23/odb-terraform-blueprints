# ─────────────────────────────────────────────────────────────────────────────
# Oracle Database@Azure — Resource Anchor — fill in your values here.
#
# The Resource Anchor is the first thing you create on Database@Azure: it maps an
# existing Azure resource group to an OCI compartment. The resource group must
# already exist; the anchor inherits its region.
#
# Commented lines show OPTIONAL parameters with default/sample values.
# ─────────────────────────────────────────────────────────────────────────────

subscription_id = "00000000-0000-0000-0000-000000000000"

resource_anchors = {
  ra1 = {
    name                = "ra-eastus"
    resource_group_name = "rg-oracle-prod"

    # ── optional (defaults shown) ──
    # tags = { env = "prod" }
  }
}
