# ── Pluggable Database ────────────────────────────────────────────────────────
# Creates one PDB inside an existing CDB.
#
# The password is NOT here. Before applying:
#   export TF_VAR_pdb_admin_password='YourStr0ng#Pass'

oci_region = "us-ashburn-1"

# From the cdb template:  terraform output cdb_id
container_database_id = "ocid1.database.oc1.iad.xxxx"

pdb_name = "SALESAPP"

# Defaults to pdb_admin_password when unset. Supply via
# TF_VAR_tde_wallet_password if you want them different.
# tde_wallet_password = ""
