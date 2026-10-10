# ─────────────────────────────────────────────────────────────────────────────
# Oracle Database — many DB Homes, each with many CDBs, each with many PDBs.
#
# Scale by editing this file only:
#   • add a DB Home -> add an entry to `db_homes`
#   • add a CDB     -> add an entry to that home's nested `cdbs` map
#   • add a PDB     -> add an entry to that CDB's nested `pdbs` map
#
# Commented lines inside the entries show OPTIONAL parameters with default/sample
# values — uncomment and edit any you need.
#
# Passwords are NOT set here — supply them as JSON via environment variables, keyed
# to match the map keys ("<home>.<cdb>" for CDBs, "<home>.<cdb>.<pdb>" for PDBs):
#   export TF_VAR_cdb_admin_passwords='{"home19.sales":"Str0ng#1","home19.hr":"Str0ng#2","home23.dw":"Str0ng#3"}'
#   export TF_VAR_pdb_admin_passwords='{"home19.sales.app":"Str0ng#4","home19.sales.rpt":"Str0ng#5","home19.hr.emp":"Str0ng#6","home23.dw.mart":"Str0ng#7"}'
# ─────────────────────────────────────────────────────────────────────────────

oci_region      = "us-ashburn-1"
vm_cluster_ocid = "ocid1.cloudvmcluster.oc1.iad.xxxxxxxx" # default cluster for all homes

# ── DB Homes (each its own Oracle version), their CDBs, and their PDBs ─────────
db_homes = {
  home19 = {
    db_version = "19.28.0.0.0"

    # ── optional per-home (defaults shown) ──
    # display_name    = "home19"                                  # defaults to the home key
    # vm_cluster_ocid = "ocid1.cloudvmcluster.oc1.iad.yyyyyyyy"   # put this home on a different cluster

    cdbs = {
      sales = {
        db_name = "SALES"

        # ── optional per-CDB (defaults shown) ──
        # character_set           = "AL32UTF8"
        # ncharacter_set          = "AL16UTF16"
        # db_unique_name          = ""           # defaults to db_name
        # sid_prefix              = ""
        # auto_backup_enabled     = false
        # auto_backup_window      = "SLOT_TWO"   # used only when auto_backup_enabled = true
        # recovery_window_in_days = 30           # used only when auto_backup_enabled = true

        pdbs = {
          app = { pdb_name = "SALESAPP" }
          rpt = { pdb_name = "SALESRPT" }
        }
      }
      hr = {
        db_name             = "HR"
        auto_backup_enabled = true
        pdbs = {
          emp = { pdb_name = "HREMP" }
        }
      }
    }
  }

  home23 = {
    db_version = "23.0.0.0"
    cdbs = {
      dw = {
        db_name = "DW"
        pdbs = {
          mart = { pdb_name = "DWMART" }
        }
      }
    }
  }
}

# ── Custom NSGs (optional) ────────────────────────────────────────────────────
# The VM cluster sits in an OCI VCN, so rules controlling who reaches the
# databases are OCI objects. Leave nsgs unset and nothing here applies.
#
# This creates the NSG and its rules; it does NOT attach it. Take nsg_id from the
# outputs and attach it to the database VNICs or subnet in OCI.
#
# compartment_id = "ocid1.compartment.oc1..xxxx"   # default for entries below
#
# nsgs = {
#   db_access = {
#     display_name = "exadata-db-access"
#     vcn_id       = "ocid1.vcn.oc1.iad.xxxx"   # the VCN the VM cluster is in
#
#     rules = {
#       sqlnet_from_app = {
#         direction   = "INGRESS"
#         protocol    = "6"            # TCP
#         source      = "10.20.0.0/16"
#         min_port    = 1521
#         description = "SQL*Net from the application subnet"
#       }
#       ons_from_app = {
#         direction   = "INGRESS"
#         protocol    = "6"
#         source      = "10.20.0.0/16"
#         min_port    = 6200
#         description = "ONS / FAN events"
#       }
#       ssh_from_bastion = {
#         direction   = "INGRESS"
#         protocol    = "6"
#         source      = "10.20.5.0/24"
#         min_port    = 22
#         description = "SSH from bastion"
#       }
#       all_egress = {
#         direction   = "EGRESS"
#         protocol    = "all"          # no ports with "all"
#         destination = "0.0.0.0/0"
#         description = "Unrestricted egress"
#       }
#     }
#   }
# }

# ── DNS forwarders (optional) ─────────────────────────────────────────────────
# Lets the databases resolve names held outside OCI — an on-prem zone, a
# corporate resolver, another cloud's private DNS.
#
# ⚠ The rules are AUTHORITATIVE: Terraform replaces the resolver's ENTIRE rule
# array. Any rule already on that resolver and not listed here is removed. Check
# what is there before the first apply:
#   oci dns resolver get --resolver-id <ocid> --scope PRIVATE --query 'data.rules'
#
# dns_forwarders = {
#   prod = {
#     vcn_id        = "ocid1.vcn.oc1.iad.xxxx"      # the VM cluster's VCN
#     subnet_id     = "ocid1.subnet.oc1.iad.xxxx"   # subnet to host the endpoint
#     endpoint_name = "prodOnpremFwd"               # alphanumeric ONLY — no hyphens
#     nsg_ids       = ["ocid1.networksecuritygroup.oc1.iad.xxxx"]  # needs egress :53
#
#     # First match wins, and keys are evaluated in ALPHABETICAL order — name them
#     # so the intended precedence falls out that way when domains overlap.
#     rules = {
#       corp = {
#         qname_cover_conditions = ["corp.example.com", "ad.example.com"]
#         destination_addresses  = ["10.1.1.10", "10.1.1.11"]   # on-prem resolvers
#       }
#       partner = {
#         qname_cover_conditions = ["partner.example.net"]
#         destination_addresses  = ["10.2.5.10"]
#         # Restrict to queries from these client CIDRs; omit for all clients.
#         # client_address_conditions = ["10.0.1.0/24"]
#       }
#     }
#   }
# }

# ── Autonomous (ADB-D) ────────────────────────────────────────────────────────
# A SECOND, independent chain: Autonomous VM Cluster -> Autonomous Container
# Database -> Autonomous Database. One level shallower than the chain above,
# because Autonomous has no DB Home. Leave this commented out and nothing here
# applies — the homes/CDBs/PDBs above are unaffected either way.
#
# The cluster OCID is the `ocid` output of db-at-aws's autonomous-vm-cluster
# module (the OCI OCID, not the AWS id or ARN):
#   cd ../db-at-aws && terraform output -json autonomous_vm_clusters | jq -r '.avmc1.ocid'
#
# autonomous_vm_cluster_ocid = "ocid1.cloudautonomousvmcluster.oc1.iad.xxxx"
#
# autonomous_container_dbs = {
#   acd1 = {
#     display_name = "acd-prod"
#
#     # ── optional per-container (defaults shown) ──
#     # cloud_autonomous_vm_cluster_ocid = ""    # put this container on a different cluster
#     # compartment_id                   = ""    # blank inherits the cluster's compartment
#     # patch_model                      = "RELEASE_UPDATES"   # or RELEASE_UPDATE_REVISIONS
#     # db_name                          = ""    # blank lets the service generate one
#     # db_version                       = ""    # blank takes the cluster default; drift ignored
#     # distribution_affinity            = ""    # MINIMUM_DISTRIBUTION | MAXIMUM_DISTRIBUTION
#     # backup_recovery_window_in_days   = 14
#     # customer_contacts                = ["dba@example.com"]
#     # maintenance_window = {
#     #   preference    = "CUSTOM_PREFERENCE"    # or NO_PREFERENCE
#     #   patching_mode = "ROLLING"              # or NONROLLING
#     #   days_of_week  = ["SUNDAY"]
#     #   hours_of_day  = [2]
#     # }
#
#     autonomous_dbs = {
#       sales = {
#         db_name       = "SALESADB"
#         compute_count = 2            # ECPUs (compute_model defaults to "ECPU")
#
#         # ── optional per-database (defaults shown) ──
#         # display_name                        = ""      # falls back to db_name
#         # compartment_id                      = ""      # falls back to the container's, then top-level
#         # db_workload                         = "OLTP"  # or DW
#         # data_storage_size_in_tbs            = 1
#         # is_auto_scaling_enabled             = false
#         # is_auto_scaling_for_storage_enabled = false
#         # is_mtls_connection_required         = true
#         # compute_model  = "OCPU"   # the older model — then use cpu_core_count, not compute_count
#         # cpu_core_count = 2
#       }
#     }
#   }
# }

# ── ADB ADMIN passwords ───────────────────────────────────────────────────────
# Each Autonomous Database needs EXACTLY ONE of the two routes below. A
# precondition fails the plan if a database has both or neither.
#
# PREFERRED — an OCI Vault secret. The resource stores the reference, so the
# password never enters Terraform state. These OCIDs are safe to keep in this
# file: an OCID is not a credential, and reading the secret needs IAM permission
# on the vault. Omit secret_version_number to follow the current version, so a
# rotation in Vault needs no config change here.
#
# adb_admin_password_secrets = {
#   "acd1.sales" = { secret_id = "ocid1.vaultsecret.oc1.iad.xxxx" }
#   "acd1.rpt"   = { secret_id = "ocid1.vaultsecret.oc1.iad.yyyy", secret_version_number = 3 }
# }
#
# FALLBACK — the literal value, which DOES land in state in cleartext, the same
# as the CDB/PDB passwords above. Never write it here; supply it by environment
# variable, keyed "<acdKey>.<adbKey>":
#   export TF_VAR_adb_admin_passwords='{"acd1.sales":"Str0ng#8"}'
