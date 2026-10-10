# Oracle Database — many DB Homes, each with many CDBs, each with many PDBs
#
# Hierarchy: VM cluster -> DB Homes -> CDBs -> PDBs.
#   • a DB Home is created on a VM cluster
#   • each DB Home hosts one or more CDBs
#   • each CDB hosts one or more PDBs
#   • a CDB belongs to exactly one Home; a PDB belongs to exactly one CDB
#
# Scale by editing terraform.tfvars only: add a home / CDB / PDB by adding a map
# entry at the matching level. No .tf edits. Layers on EXISTING Exadata VM
# cluster(s) (created by db-at-aws / db-at-gcp / db-at-azure, or native OCI).

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 7.11.0"
    }
  }
}

# Auth comes from ~/.oci/config or OCI_* / TF_VAR_* env vars — no secrets here.
provider "oci" {
  region = var.oci_region
}

# ── DB Homes — one entry per home in var.db_homes ─────────────────────────────
module "db_home" {
  source   = "./modules/db-home"
  for_each = var.db_homes

  vm_cluster_ocid = each.value.vm_cluster_ocid != "" ? each.value.vm_cluster_ocid : var.vm_cluster_ocid
  display_name    = each.value.display_name != "" ? each.value.display_name : each.key
  db_version      = each.value.db_version
}

# ── Flatten homes -> cdbs (key "<homeKey>.<cdbKey>") and homes -> cdbs -> pdbs ─
locals {
  cdb_list = flatten([
    for hk, hv in var.db_homes : [
      for ck, cv in hv.cdbs : {
        key                     = "${hk}.${ck}"
        home_key                = hk
        db_name                 = cv.db_name
        character_set           = cv.character_set
        ncharacter_set          = cv.ncharacter_set
        db_unique_name          = cv.db_unique_name
        sid_prefix              = cv.sid_prefix
        auto_backup_enabled     = cv.auto_backup_enabled
        auto_backup_window      = cv.auto_backup_window
        recovery_window_in_days = cv.recovery_window_in_days
      }
    ]
  ])
  cdb_instances = { for c in local.cdb_list : c.key => c }

  pdb_list = flatten([
    for hk, hv in var.db_homes : [
      for ck, cv in hv.cdbs : [
        for pk, pv in cv.pdbs : {
          key      = "${hk}.${ck}.${pk}"
          cdb_key  = "${hk}.${ck}"
          pdb_name = pv.pdb_name
        }
      ]
    ]
  ])
  pdb_instances = { for p in local.pdb_list : p.key => p }
}

# ── Container Databases — one per "<homeKey>.<cdbKey>" ─────────────────────────
module "cdb" {
  source   = "./modules/cdb"
  for_each = local.cdb_instances

  db_home_id              = module.db_home[each.value.home_key].db_home_id
  db_name                 = each.value.db_name
  admin_password          = var.cdb_admin_passwords[each.key]
  character_set           = each.value.character_set
  ncharacter_set          = each.value.ncharacter_set
  db_unique_name          = each.value.db_unique_name
  sid_prefix              = each.value.sid_prefix
  auto_backup_enabled     = each.value.auto_backup_enabled
  auto_backup_window      = each.value.auto_backup_window
  recovery_window_in_days = each.value.recovery_window_in_days

  depends_on = [module.db_home]
}

# ── Pluggable Databases — one per "<homeKey>.<cdbKey>.<pdbKey>" ────────────────
module "pdb" {
  source   = "./modules/pdb"
  for_each = local.pdb_instances

  container_database_id = module.cdb[each.value.cdb_key].cdb_id
  pdb_name              = each.value.pdb_name
  pdb_admin_password    = var.pdb_admin_passwords[each.key]

  depends_on = [module.cdb]
}

# ── Custom NSGs (optional) ────────────────────────────────────────────────────
# Rules for reaching the databases live in the OCI VCN the VM cluster sits in.
# Leave var.nsgs empty and nothing here applies.
#
# Independent of the home/CDB/PDB chain above — no depends_on, so these apply in
# parallel with the databases rather than after them.
module "nsg" {
  source   = "./modules/nsg"
  for_each = var.nsgs

  compartment_id = each.value.compartment_id != "" ? each.value.compartment_id : var.compartment_id
  vcn_id         = each.value.vcn_id
  display_name   = each.value.display_name
  freeform_tags  = each.value.freeform_tags
  rules          = each.value.rules
}

# A compartment must resolve for every NSG — either its own or the top-level
# default. Catch a missing one at plan time rather than on the create call.
check "nsg_compartment_resolves" {
  assert {
    condition = alltrue([
      for k, n in var.nsgs :
      n.compartment_id != "" || var.compartment_id != ""
    ])
    error_message = "These NSGs have no compartment: set the top-level compartment_id, or compartment_id on each entry."
  }
}

# ── DNS forwarders (optional) ─────────────────────────────────────────────────
# Forwarding endpoint + FORWARD rules on a VM cluster VCN's resolver, so the
# databases can resolve names held outside OCI.
#
# Independent of the database chain and of the NSGs — applies in parallel.
module "dns_forwarder" {
  source   = "./modules/dns-forwarder"
  for_each = var.dns_forwarders

  vcn_id                = each.value.vcn_id
  subnet_id             = each.value.subnet_id
  endpoint_name         = each.value.endpoint_name
  resolver_id           = each.value.resolver_id
  forwarding_address    = each.value.forwarding_address
  nsg_ids               = each.value.nsg_ids
  resolver_display_name = each.value.resolver_display_name
  rules                 = each.value.rules
}

# ── Autonomous (ADB-D): containers, then the databases inside them ─────────────
# Parallel to the db_homes chain above and independent of it — no depends_on, so
# an all-in-one apply builds both at once. Leave autonomous_container_dbs empty
# and nothing here applies.
#
# One level shallower than the non-autonomous chain: there is no DB Home, so the
# keys are "<acdKey>" and "<acdKey>.<adbKey>" rather than three deep.
module "autonomous_container_db" {
  source   = "./modules/autonomous-container-db"
  for_each = var.autonomous_container_dbs

  cloud_autonomous_vm_cluster_ocid = each.value.cloud_autonomous_vm_cluster_ocid != "" ? each.value.cloud_autonomous_vm_cluster_ocid : var.autonomous_vm_cluster_ocid
  display_name                     = each.value.display_name
  patch_model                      = each.value.patch_model
  compartment_id                   = each.value.compartment_id != "" ? each.value.compartment_id : var.compartment_id
  db_name                          = each.value.db_name
  db_unique_name                   = each.value.db_unique_name
  db_version                       = each.value.db_version

  service_level_agreement_type = each.value.service_level_agreement_type
  distribution_affinity        = each.value.distribution_affinity
  net_services_architecture    = each.value.net_services_architecture
  version_preference           = each.value.version_preference

  db_split_threshold         = each.value.db_split_threshold
  vm_failover_reservation    = each.value.vm_failover_reservation
  is_dst_file_update_enabled = each.value.is_dst_file_update_enabled

  kms_key_id                     = each.value.kms_key_id
  vault_id                       = each.value.vault_id
  backup_recovery_window_in_days = each.value.backup_recovery_window_in_days
  customer_contacts              = each.value.customer_contacts
  maintenance_window             = each.value.maintenance_window

  freeform_tags = each.value.freeform_tags
  defined_tags  = each.value.defined_tags
}

# Flatten containers -> autonomous databases, key "<acdKey>.<adbKey>".
locals {
  adb_list = flatten([
    for ak, av in var.autonomous_container_dbs : [
      for dk, dv in av.autonomous_dbs : {
        key     = "${ak}.${dk}"
        acd_key = ak
        adb     = dv
        # Compartment resolution walks up: the database's own, then its
        # container's, then the top-level default. The provider requires one on
        # this resource — unlike the container, it is not inherited from the
        # cluster.
        compartment_id = coalesce(
          dv.compartment_id != "" ? dv.compartment_id : null,
          av.compartment_id != "" ? av.compartment_id : null,
          var.compartment_id != "" ? var.compartment_id : null,
          "",
        )
      }
    ]
  ])
  adb_instances = { for a in local.adb_list : a.key => a }
}

module "autonomous_db" {
  source   = "./modules/autonomous-db"
  for_each = local.adb_instances

  autonomous_container_database_id = module.autonomous_container_db[each.value.acd_key].acd_id
  compartment_id                   = each.value.compartment_id
  db_name                          = each.value.adb.db_name
  display_name                     = each.value.adb.display_name

  # Vault secret if one is registered for this key, otherwise the literal. The
  # module sends only one of them; the check below rejects both at plan time.
  admin_password_secret_id             = try(var.adb_admin_password_secrets[each.key].secret_id, "")
  admin_password_secret_version_number = try(var.adb_admin_password_secrets[each.key].secret_version_number, null)
  admin_password                       = try(var.adb_admin_passwords[each.key], "")

  compute_model                       = each.value.adb.compute_model
  compute_count                       = each.value.adb.compute_count
  cpu_core_count                      = each.value.adb.cpu_core_count
  data_storage_size_in_tbs            = each.value.adb.data_storage_size_in_tbs
  is_auto_scaling_enabled             = each.value.adb.is_auto_scaling_enabled
  is_auto_scaling_for_storage_enabled = each.value.adb.is_auto_scaling_for_storage_enabled

  db_workload                          = each.value.adb.db_workload
  db_version                           = each.value.adb.db_version
  database_edition                     = each.value.adb.database_edition
  license_model                        = each.value.adb.license_model
  character_set                        = each.value.adb.character_set
  ncharacter_set                       = each.value.adb.ncharacter_set
  in_memory_percentage                 = each.value.adb.in_memory_percentage
  is_mtls_connection_required          = each.value.adb.is_mtls_connection_required
  autonomous_maintenance_schedule_type = each.value.adb.autonomous_maintenance_schedule_type

  kms_key_id        = each.value.adb.kms_key_id
  vault_id          = each.value.adb.vault_id
  customer_contacts = each.value.adb.customer_contacts
  freeform_tags     = each.value.adb.freeform_tags
  defined_tags      = each.value.adb.defined_tags

  depends_on = [module.autonomous_container_db]
}
