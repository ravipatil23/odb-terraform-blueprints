# ─────────────────────────────────────────────────────────────────────────────
# Oracle Database@Azure — fill in your values here. This is the ONLY file you
# normally need to edit. Add more entries to any map to create more resources.
# The resource group must already exist.
#
# Commented lines show OPTIONAL parameters with their default/sample values —
# uncomment and edit any you need. Uncommented lines are required (or recommended).
# ─────────────────────────────────────────────────────────────────────────────

subscription_id     = "00000000-0000-0000-0000-000000000000"
resource_group_name = "rg-oracle-prod"
location            = "eastus"

tags = {
  Environment = "dev"
  ManagedBy   = "Terraform"
}

# ── Resource Anchors (optional) ───────────────────────────────────────────────
# Maps a resource group to an OCI compartment. The foundational Database@Azure
# resource - the Network Anchor, Exadata infrastructure and VM clusters all need
# one to exist in the resource group first.
#
# Leave both maps empty and this blueprint behaves exactly as before: no anchor is
# created and nothing else changes.
#
# azure_resource_anchors = {
#   anchor1 = {
#     name = "anchor-oracle-prod"
#     # resource_group_name = "rg-other"   # defaults to the stack resource_group_name
#   }
# }

# Already have an anchor, provisioned by hand or by a platform team? Give its ID
# here instead of describing it above, and reference the same key from
# azure_network_anchors.anchor_ref. Entries here are referenced only: Terraform
# never creates, changes or destroys them. Keep each anchor in one map or the
# other - a key in both is rejected before apply.
#
# existing_resource_anchor_ids = {
#   anchor1 = "/subscriptions/.../resourceGroups/rg-oracle-prod/providers/Oracle.Database/resourceAnchors/anchor-oracle-prod"
# }

# ── Network Anchors (optional) ────────────────────────────────────────────────
# Bridges a delegated subnet to OCI. Required for an Oracle Base Database; not
# needed for Exadata VM clusters alone.
#
# anchor_ref matches a key in azure_resource_anchors or existing_resource_anchor_ids.
# vnet_ref matches a key in azure_vnets and supplies the delegated subnet.
#
# azure_network_anchors = {
#   netanchor1 = {
#     name       = "netanchor-prod"        # 3-24 chars, letters/numbers/hyphens
#     anchor_ref = "anchor1"
#     vnet_ref   = "vnet1"
#     zones      = ["2"]                   # AZ the Base Database will reside in
#
#     # oci_vcn_dns_label     = "prodvcn"
#     # oci_backup_cidr_block = "10.0.2.0/24"   # not needed for Base Database
#
#     # ── DNS (all default false) ──
#     # Leave dns_listening_endpoint_enabled OFF on an anchor that fronts the
#     # central DNS hub in ../azure-dns-hub - that blueprint creates the hub's
#     # listening endpoint itself, in a resolver subnet it owns. Enabling it here
#     # too would put a second, unwired listener on the same resolver.
#     # dns_listening_endpoint_enabled  = true          # Azure apps resolve DB FQDNs
#     # dns_listening_allowed_cidrs     = "10.0.0.0/16" # comma-separated
#     # dns_forwarding_endpoint_enabled = true          # DB instances resolve Azure FQDNs
#     # dns_forwarding_rules = [
#     #   { domain_names = "corp.example.com", forwarding_ip_address = "10.0.0.4" },
#     # ]
#     # dns_zone_sync_enabled = true                    # replicate DB zones into Azure
#   }
# }

# ── VNets (+ Oracle-delegated subnet) ─────────────────────────────────────────
azure_vnets = {
  vnet1 = {
    vnet_name             = "vnet-oracle-eastus"
    address_space         = "10.20.0.0/16"
    subnet_name           = "snet-oracle-delegated"
    subnet_address_prefix = "10.20.1.0/24"
    # (no optional fields — all four are required)
  }
}

# ── Exadata Infrastructures ───────────────────────────────────────────────────
azure_infras = {
  infra1 = {
    name         = "exa-prod-eastus"
    display_name = "Exadata Prod EastUS"
    zone         = "2"

    # ── optional (defaults shown) ──
    # shape         = "Exadata.X11M"
    # compute_count = 2
    # storage_count = 3
  }
}

# ── VM Clusters ───────────────────────────────────────────────────────────────
# infra_ref / vnet_ref must match keys above.
azure_clusters = {
  vmc1 = {
    name         = "vmc-prod-eastus"
    display_name = "VM Cluster Prod"
    hostname     = "exadb"
    infra_ref    = "infra1"
    vnet_ref     = "vnet1"
    ssh_public_keys = [
      "ssh-rsa AAAAB3Nza... replace-with-your-key",
    ]

    # ── optional (defaults shown) ──
    # cpu_core_count              = 4
    # data_storage_size_in_tbs    = 2
    # memory_size_in_gbs          = 60
    # db_node_storage_size_in_gbs = 120
    # gi_version                  = "23.0.0.0"
    # license_model               = "LicenseIncluded"  # or BringYourOwnLicense
    # local_backup_enabled        = false
    # sparse_diskgroup_enabled    = false
    # cluster_name                = ""        # optional cluster name
    # time_zone                   = "UTC"
    # scan_listener_port_tcp      = 1521
    # backup_subnet_cidr          = "192.168.252.0/22"  # see the note below
  }

  # ── Adding a second cluster on the SAME delegated subnet ──────────────────
  # Reuse the subnet by pointing at the same vnet_ref. The delegated subnet is
  # shared by design; the backup range is not — Oracle carves it inside the VNet
  # per cluster, so give each cluster its own non-overlapping range once more
  # than one cluster shares a vnet_ref. Both clusters default to the same
  # 192.168.252.0/22, so the second one MUST be given a different range or the
  # apply fails on a collision. Never set it to "" — an empty value makes every
  # later plan propose replacing the cluster.
  #
  # vmc2 = {
  #   name               = "vmc-reporting-eastus"
  #   display_name       = "VM Cluster Reporting"
  #   hostname           = "rpt"
  #   infra_ref          = "infra1"
  #   vnet_ref           = "vnet1"          # same delegated subnet as vmc1
  #   backup_subnet_cidr = "10.0.11.0/24"   # vmc1's must differ, e.g. 10.0.10.0/24
  #   ssh_public_keys    = ["ssh-rsa AAAAB3Nza... replace-with-your-key"]
  # }
}

# ── Autonomous Databases — Serverless (optional) ──────────────────────────────
# Oracle Autonomous Database Serverless. Nothing here depends on azure_infras or
# azure_clusters: Oracle runs the fleet, so there is no Exadata Infrastructure or
# VM Cluster underneath and no infra_ref. You can leave those two maps empty and
# deploy only Autonomous databases.
#
# vnet_ref is a key in azure_vnets and gives a PRIVATE endpoint on the
# Oracle-delegated subnet. Omit it for a public endpoint and list allowed_ips.
#
# The ADMIN password is never written here. Export it before you apply, keyed by
# the same map key:
#
#   export TF_VAR_autonomous_db_admin_passwords='{"adb1":"YourStr0ngPass"}'
#
#   PowerShell:
#   $env:TF_VAR_autonomous_db_admin_passwords = '{"adb1":"YourStr0ngPass"}'
#
# 12-30 chars, upper + lower + digit, no double quote, cannot contain "admin".
#
# azure_autonomous_dbs = {
#   adb1 = {
#     name         = "adb-prod-eastus"
#     display_name = "Autonomous Prod"
#     vnet_ref     = "vnet1"          # private endpoint on the delegated subnet
#
#     # ── optional (defaults shown) ──
#     # db_workload                      = "OLTP"       # or DW, AJD, APEX
#     # db_version                       = "23ai"       # or 19c
#     # license_model                    = "LicenseIncluded"  # or BringYourOwnLicense
#     # compute_model                    = "ECPU"       # OCPU is legacy
#     # compute_count                    = 2            # minimum 2 ECPUs
#     # data_storage_size_in_tbs         = 1            # minimum 1
#     # auto_scaling_enabled             = false        # compute up to 3x on demand
#     # auto_scaling_for_storage_enabled = false
#     # backup_retention_period_in_days  = 60           # 1-60
#     # character_set                    = "AL32UTF8"
#     # national_character_set           = "AL16UTF16"
#     # mtls_connection_required         = true         # false allows TLS-only
#     # customer_contacts                = ["dba@example.com"]
#     # allowed_ips                      = []           # public ACL; only without vnet_ref
#   }
#
#   # A public-endpoint database, locked to a couple of office ranges. Leave
#   # vnet_ref out entirely — allowed_ips is ignored on a delegated subnet.
#   # adb2 = {
#   #   name         = "adb-dev-eastus"
#   #   display_name = "Autonomous Dev"
#   #   db_workload  = "DW"
#   #   allowed_ips  = ["203.0.113.0/24", "198.51.100.7"]
#   # }
# }
