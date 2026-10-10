# Variable definitions. Real values go in terraform.tfvars; passwords via env vars.

variable "oci_region" {
  description = "OCI region of the VM cluster(s), e.g. us-ashburn-1."
  type        = string
}

variable "compartment_id" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Default compartment OCID for NSGs. Override per-entry via nsgs[*].compartment_id. Only read when nsgs is non-empty."
}

# ── Custom NSGs (optional) ────────────────────────────────────────────────────
# The VM cluster sits in an OCI VCN whichever cloud fronts it, so the rules
# controlling who reaches the databases are OCI objects. Leave nsgs empty and
# this blueprint behaves exactly as before - homes, CDBs and PDBs only.
#
# Creates the NSG and its rules; it does NOT attach the NSG. No vm-cluster
# resource on any cloud takes an NSG argument - attach it to the database VNICs
# or the subnet in OCI using the exported nsg_id.
variable "nsgs" {
  description = "Custom OCI network security groups, keyed by a short name. Each needs the VCN the VM cluster sits in."
  type = map(object({
    display_name   = string
    vcn_id         = string
    compartment_id = optional(string, "") # defaults to the top-level compartment_id
    freeform_tags  = optional(map(string), {})

    rules = optional(map(object({
      direction   = string
      protocol    = optional(string, "6")
      description = optional(string, "")
      stateless   = optional(bool, false)

      source      = optional(string)
      source_type = optional(string, "CIDR_BLOCK")

      destination      = optional(string)
      destination_type = optional(string, "CIDR_BLOCK")

      min_port = optional(number)
      max_port = optional(number)

      icmp_type = optional(number)
      icmp_code = optional(number)
    })), {})
  }))
  default = {}
}

# ── DNS forwarders (optional) ─────────────────────────────────────────────────
# Lets the databases resolve names held elsewhere - an on-prem zone, a corporate
# resolver, another cloud's private DNS. Creates a forwarding endpoint on the
# VCN's resolver and the FORWARD rules that steer domains to it.
#
# ⚠ The rules are AUTHORITATIVE. Terraform replaces the resolver's whole rule
# array, so any rule already there and not listed here is removed. Check first:
#   oci dns resolver get --resolver-id <ocid> --scope PRIVATE --query 'data.rules'
#
# Leave empty and nothing here applies.
variable "dns_forwarders" {
  description = "DNS forwarders on VM cluster VCNs, keyed by a short name. One entry per VCN that needs outbound name resolution."
  type = map(object({
    vcn_id        = string
    subnet_id     = string
    endpoint_name = string # alphanumeric only - OCI rejects hyphens here

    resolver_id           = optional(string)     # discovered from vcn_id when null
    forwarding_address    = optional(string, "") # auto-assigned when empty
    nsg_ids               = optional(list(string), [])
    resolver_display_name = optional(string, "") # empty leaves the existing name

    # First match wins, and Terraform iterates keys in order - name them so the
    # intended precedence falls out alphabetically if domains overlap.
    rules = optional(map(object({
      destination_addresses     = list(string)
      qname_cover_conditions    = optional(list(string), [])
      client_address_conditions = optional(list(string), [])
    })), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, f in var.dns_forwarders :
      can(regex("^[a-zA-Z][a-zA-Z0-9]*$", f.endpoint_name))
    ])
    error_message = "endpoint_name must start with a letter and contain only letters and digits. OCI rejects hyphens, underscores and dots in resolver endpoint names."
  }

  validation {
    condition = alltrue([
      for k, f in var.dns_forwarders : alltrue([
        for rk, r in f.rules : length(r.destination_addresses) > 0
      ])
    ])
    error_message = "Each forwarding rule needs at least one entry in destination_addresses."
  }
}

variable "vm_cluster_ocid" {
  description = "Default VM cluster OCID for homes that don't set their own. Override per-home via db_homes[*].vm_cluster_ocid."
  type        = string
}

# ── DB Homes -> CDBs -> PDBs ──────────────────────────────────────────────────
# Add a home / CDB / PDB by adding a map entry at the matching level.
variable "db_homes" {
  description = "Map of Database Homes keyed by a short name. Each home has its own db_version and a nested map of CDBs; each CDB has a nested map of PDBs."
  type = map(object({
    db_version      = string
    display_name    = optional(string, "") # defaults to the home's map key
    vm_cluster_ocid = optional(string, "") # defaults to the top-level vm_cluster_ocid
    cdbs = optional(map(object({
      db_name                 = string
      character_set           = optional(string, "AL32UTF8")
      ncharacter_set          = optional(string, "AL16UTF16")
      db_unique_name          = optional(string, "")
      sid_prefix              = optional(string, "")
      auto_backup_enabled     = optional(bool, false)
      auto_backup_window      = optional(string, "SLOT_TWO")
      recovery_window_in_days = optional(number, 30)
      pdbs = optional(map(object({
        pdb_name = string
      })), {})
    })), {})
  }))
  default = {}
}

# ── Passwords (keep out of tfvars — supply as JSON via environment variables) ──
# Key = "<homeKey>.<cdbKey>"
# export TF_VAR_cdb_admin_passwords='{"home19.sales":"...","home19.hr":"..."}'
variable "cdb_admin_passwords" {
  description = "CDB admin (SYS) passwords keyed by \"<homeKey>.<cdbKey>\"."
  type        = map(string)
  default     = {}
  sensitive   = true
}

# Key = "<homeKey>.<cdbKey>.<pdbKey>"
# export TF_VAR_pdb_admin_passwords='{"home19.sales.app":"...","home19.hr.emp":"..."}'
variable "pdb_admin_passwords" {
  description = "PDB admin passwords keyed by \"<homeKey>.<cdbKey>.<pdbKey>\" (also the TDE wallet password)."
  type        = map(string)
  default     = {}
  sensitive   = true
}

# ── Autonomous (ADB-D) ────────────────────────────────────────────────────────
# A parallel chain to db_homes above, one level shallower because Autonomous has
# no DB Home:
#
#   Autonomous VM Cluster -> Autonomous Container Database -> Autonomous Database
#
# The cluster is created by db-at-aws (modules/autonomous-vm-cluster); its `ocid`
# output is what goes in here. Leave autonomous_container_dbs empty and none of
# this applies — the non-autonomous chain is untouched either way.
variable "autonomous_vm_cluster_ocid" {
  description = "Default Autonomous VM Cluster OCID for the ADB-D chain, overridable per container. This is the OCI OCID (the `ocid` output of db-at-aws's autonomous-vm-cluster), not the AWS id or ARN."
  type        = string
  default     = ""
}

variable "autonomous_container_dbs" {
  description = "Autonomous Container Databases keyed by a short name, each with its own nested autonomous_dbs map."
  type = map(object({
    display_name                     = string
    cloud_autonomous_vm_cluster_ocid = optional(string, "") # defaults to autonomous_vm_cluster_ocid
    compartment_id                   = optional(string, "") # blank inherits the cluster's
    patch_model                      = optional(string, "RELEASE_UPDATES")
    db_name                          = optional(string, "")
    db_unique_name                   = optional(string, "")
    db_version                       = optional(string, "")

    service_level_agreement_type = optional(string, "")
    distribution_affinity        = optional(string, "")
    net_services_architecture    = optional(string, "")
    version_preference           = optional(string, "")

    db_split_threshold         = optional(number)
    vm_failover_reservation    = optional(number)
    is_dst_file_update_enabled = optional(bool)

    kms_key_id                     = optional(string, "")
    vault_id                       = optional(string, "")
    backup_recovery_window_in_days = optional(number)
    customer_contacts              = optional(list(string), [])

    maintenance_window = optional(object({
      preference                       = optional(string, "")
      patching_mode                    = optional(string, "")
      is_monthly_patching_enabled      = optional(bool)
      lead_time_in_weeks               = optional(number)
      hours_of_day                     = optional(list(number), [])
      days_of_week                     = optional(list(string), [])
      months                           = optional(list(string), [])
      weeks_of_month                   = optional(list(number), [])
      custom_action_timeout_in_mins    = optional(number)
      is_custom_action_timeout_enabled = optional(bool)
    }))

    freeform_tags = optional(map(string), {})
    defined_tags  = optional(map(string), {})

    # The Autonomous Databases inside this container.
    autonomous_dbs = optional(map(object({
      db_name        = string
      display_name   = optional(string, "")
      compartment_id = optional(string, "") # blank falls back to the container's, then the top-level

      compute_model                       = optional(string, "ECPU")
      compute_count                       = optional(number)
      cpu_core_count                      = optional(number)
      data_storage_size_in_tbs            = optional(number)
      is_auto_scaling_enabled             = optional(bool)
      is_auto_scaling_for_storage_enabled = optional(bool)

      db_workload                          = optional(string, "OLTP")
      db_version                           = optional(string, "")
      database_edition                     = optional(string, "")
      license_model                        = optional(string, "")
      character_set                        = optional(string, "")
      ncharacter_set                       = optional(string, "")
      in_memory_percentage                 = optional(number)
      is_mtls_connection_required          = optional(bool)
      autonomous_maintenance_schedule_type = optional(string, "")

      kms_key_id        = optional(string, "")
      vault_id          = optional(string, "")
      customer_contacts = optional(list(string), [])
      freeform_tags     = optional(map(string), {})
      defined_tags      = optional(map(string), {})
    })), {})
  }))
  default = {}
}

# ── ADB admin passwords ───────────────────────────────────────────────────────
# Two routes, and each database picks exactly one. Key = "<acdKey>.<adbKey>".
#
# Preferred — a Vault secret OCID. The resource stores the REFERENCE, so the
# password never enters Terraform state. Safe to keep in terraform.tfvars: an
# OCID is not a credential, and reading the secret needs IAM permission on the
# vault. Rotate in Vault; leave secret_version_number unset to follow the
# current version.
variable "adb_admin_password_secrets" {
  description = "ADB ADMIN passwords as OCI Vault secret references, keyed by \"<acdKey>.<adbKey>\". Preferred over adb_admin_passwords — the password stays out of Terraform state."
  type = map(object({
    secret_id             = string
    secret_version_number = optional(number)
  }))
  default = {}
}

# Fallback — the literal value, which DOES land in state in cleartext. Supply it
# by environment variable, the same way the CDB/PDB passwords are supplied:
# export TF_VAR_adb_admin_passwords='{"acd1.sales":"..."}'
variable "adb_admin_passwords" {
  description = "ADB ADMIN passwords as literals keyed by \"<acdKey>.<adbKey>\". Lands in state in cleartext — prefer adb_admin_password_secrets."
  type        = map(string)
  default     = {}
  sensitive   = true
}
