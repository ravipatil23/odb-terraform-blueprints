# Oracle Database@Azure — reusable root module
#
# Fill in terraform.tfvars and run. Add entries to the maps to scale — no need
# to edit this file.
#
# Flow: Resource Anchor -> VNet (+ delegated subnet) -> Network Anchor
#                       -> Exadata Infrastructure -> VM Cluster
#
# Anchors are optional: leave azure_resource_anchors / azure_network_anchors empty
# and this behaves exactly as before. Point at anchors a platform team already
# created with existing_resource_anchor_ids instead.

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.51.0"
    }
    # Network Anchors only. azurerm has no native resource for
    # Oracle.Database/networkAnchors, so that one module goes through azapi.
    # Declared unconditionally because required_providers cannot be conditional;
    # with azure_network_anchors empty, nothing is created.
    azapi = {
      source  = "Azure/azapi"
      version = ">= 2.8.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

provider "azapi" {
  subscription_id = var.subscription_id
}

# ── Resource Anchors ──────────────────────────────────────────────────────────
# Maps a resource group to an OCI compartment. Foundational: everything else on
# Database@Azure needs one to exist in the resource group first.
module "resource_anchor" {
  source   = "./modules/resource-anchor"
  for_each = var.azure_resource_anchors

  name                = each.value.name
  resource_group_name = coalesce(each.value.resource_group_name, var.resource_group_name)
  tags                = var.tags
}

# One keyspace covering anchors this blueprint creates and anchors that already
# exist, so anchor_ref resolves the same way whichever side one lives on.
#
# Merged rather than a conditional on purpose: both branches of a ?: are
# evaluated, so indexing a module for a key that was never created fails even on
# the branch that is not taken.
locals {
  resource_anchor_ids = merge(
    { for k, m in module.resource_anchor : k => m.id },
    var.existing_resource_anchor_ids,
  )
}

# A key defined in both maps would create the anchor *and* wire everything to the
# pre-existing one, orphaning what was just built. Catch it before apply.
check "no_duplicate_resource_anchor_keys" {
  assert {
    condition = length(setintersection(keys(var.azure_resource_anchors), keys(var.existing_resource_anchor_ids))) == 0
    error_message = format(
      "These keys appear in both azure_resource_anchors and existing_resource_anchor_ids: %s. Keep each anchor in one map only - describe it to create it, or give its ID to reuse it.",
      join(", ", setintersection(keys(var.azure_resource_anchors), keys(var.existing_resource_anchor_ids))),
    )
  }
}

# ── VNets + delegated subnets ─────────────────────────────────────────────────
module "vnet" {
  source   = "./modules/vnet"
  for_each = var.azure_vnets

  resource_group_name   = var.resource_group_name
  location              = var.location
  vnet_name             = each.value.vnet_name
  address_space         = each.value.address_space
  subnet_name           = each.value.subnet_name
  subnet_address_prefix = each.value.subnet_address_prefix
  tags                  = var.tags
}

# ── Network Anchors ───────────────────────────────────────────────────────────
# Bridges a delegated subnet to OCI. anchor_ref must match a key in
# azure_resource_anchors or existing_resource_anchor_ids; vnet_ref a key in
# azure_vnets.
module "network_anchor" {
  source   = "./modules/network-anchor"
  for_each = var.azure_network_anchors

  subscription_id     = var.subscription_id
  name                = each.value.name
  resource_group_name = coalesce(each.value.resource_group_name, var.resource_group_name)
  location            = coalesce(each.value.location, var.location)
  resource_anchor_id  = local.resource_anchor_ids[each.value.anchor_ref]
  subnet_id           = module.vnet[each.value.vnet_ref].subnet_id
  zones               = each.value.zones
  tags                = var.tags

  oci_vcn_dns_label     = each.value.oci_vcn_dns_label
  oci_backup_cidr_block = each.value.oci_backup_cidr_block

  dns_listening_endpoint_enabled  = each.value.dns_listening_endpoint_enabled
  dns_listening_allowed_cidrs     = each.value.dns_listening_allowed_cidrs
  dns_forwarding_endpoint_enabled = each.value.dns_forwarding_endpoint_enabled
  dns_forwarding_rules            = each.value.dns_forwarding_rules
  dns_zone_sync_enabled           = each.value.dns_zone_sync_enabled

  depends_on = [module.vnet]
}

# ── Exadata Infrastructures ───────────────────────────────────────────────────
module "exadata_infra" {
  source   = "./modules/exadata-infra"
  for_each = var.azure_infras

  resource_group_name = var.resource_group_name
  location            = var.location
  name                = each.value.name
  display_name        = each.value.display_name
  shape               = each.value.shape
  compute_count       = each.value.compute_count
  storage_count       = each.value.storage_count
  zone                = each.value.zone
  tags                = var.tags

  # Nothing on the infra takes the anchor's ID, but the anchor must exist in the
  # resource group first. With no anchors configured this is a no-op.
  depends_on = [module.resource_anchor]
}

# ── VM Clusters ───────────────────────────────────────────────────────────────
# infra_ref / vnet_ref must match keys in azure_infras / azure_vnets.
module "vm_cluster" {
  source   = "./modules/vm-cluster"
  for_each = var.azure_clusters

  resource_group_name             = var.resource_group_name
  location                        = var.location
  name                            = each.value.name
  display_name                    = each.value.display_name
  hostname                        = each.value.hostname
  cpu_core_count                  = each.value.cpu_core_count
  data_storage_size_in_tbs        = each.value.data_storage_size_in_tbs
  memory_size_in_gbs              = each.value.memory_size_in_gbs
  db_node_storage_size_in_gbs     = each.value.db_node_storage_size_in_gbs
  gi_version                      = each.value.gi_version
  license_model                   = each.value.license_model
  ssh_public_keys                 = each.value.ssh_public_keys
  local_backup_enabled            = each.value.local_backup_enabled
  sparse_diskgroup_enabled        = each.value.sparse_diskgroup_enabled
  cluster_name                    = each.value.cluster_name
  time_zone                       = each.value.time_zone
  scan_listener_port_tcp          = each.value.scan_listener_port_tcp
  backup_subnet_cidr              = each.value.backup_subnet_cidr
  cloud_exadata_infrastructure_id = module.exadata_infra[each.value.infra_ref].infra_id
  subnet_id                       = module.vnet[each.value.vnet_ref].subnet_id
  virtual_network_id              = module.vnet[each.value.vnet_ref].vnet_id
  tags                            = var.tags

  depends_on = [module.exadata_infra, module.vnet]
}

# ── Autonomous Databases (Serverless) ─────────────────────────────────────────
# Serverless has no Exadata Infrastructure under it — Oracle runs the fleet, so
# this map is independent of azure_infras / azure_clusters. It attaches to the
# same Oracle-delegated subnet the VM clusters use.
#
# vnet_ref is optional: a key in azure_vnets gives a private endpoint on that
# delegated subnet; null gives a public endpoint governed by allowed_ips.
module "autonomous_db" {
  source   = "./modules/autonomous-db"
  for_each = var.azure_autonomous_dbs

  resource_group_name = var.resource_group_name
  location            = var.location
  name                = each.value.name
  display_name        = each.value.display_name

  db_workload   = each.value.db_workload
  db_version    = each.value.db_version
  license_model = each.value.license_model
  compute_model = each.value.compute_model
  compute_count = each.value.compute_count

  data_storage_size_in_tbs         = each.value.data_storage_size_in_tbs
  auto_scaling_enabled             = each.value.auto_scaling_enabled
  auto_scaling_for_storage_enabled = each.value.auto_scaling_for_storage_enabled
  backup_retention_period_in_days  = each.value.backup_retention_period_in_days

  character_set          = each.value.character_set
  national_character_set = each.value.national_character_set

  mtls_connection_required = each.value.mtls_connection_required
  allowed_ips              = each.value.allowed_ips
  customer_contacts        = each.value.customer_contacts

  # Indexed, not looked up: a missing password should stop the plan rather than
  # reach the provider as null. The check below names the offending key first.
  admin_password = var.autonomous_db_admin_passwords[each.key]

  # A null vnet_ref means public access, so send empty strings — the module
  # turns those into null, which is what the Optional schema wants.
  subnet_id          = each.value.vnet_ref == null ? "" : module.vnet[each.value.vnet_ref].subnet_id
  virtual_network_id = each.value.vnet_ref == null ? "" : module.vnet[each.value.vnet_ref].vnet_id

  tags = var.tags

  # Same ordering rule as the Exadata infra: the Resource Anchor must exist in
  # the resource group first. With no anchors configured this is a no-op.
  depends_on = [module.resource_anchor, module.vnet]
}

# Passwords come from the environment, so a typo in a key is easy to make and
# the raw failure ("key ... does not exist") does not say which map is short.
#
# The password map is sensitive, so every value derived from it carries that
# mark - including its key names, which an assertion may not report. Only the
# keys are unwrapped here; the passwords themselves are never touched.
locals {
  autonomous_db_missing_passwords = setsubtract(
    keys(var.azure_autonomous_dbs),
    nonsensitive(keys(var.autonomous_db_admin_passwords)),
  )
}

check "autonomous_db_passwords_present" {
  assert {
    condition = length(local.autonomous_db_missing_passwords) == 0
    error_message = format(
      "No ADMIN password supplied for these azure_autonomous_dbs keys: %s. Set them with TF_VAR_autonomous_db_admin_passwords='{\"key\":\"...\"}' - never in terraform.tfvars.",
      join(", ", local.autonomous_db_missing_passwords),
    )
  }
}
