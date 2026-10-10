# ── Container Database ────────────────────────────────────────────────────────
# Creates one CDB in an existing DB Home.
#
# The password is NOT here. Before applying:
#   export TF_VAR_admin_password='YourStr0ng#Pass'

oci_region = "us-ashburn-1"

# From the db-home template:  terraform output db_home_id
db_home_id = "ocid1.dbhome.oc1.iad.xxxx"

db_name = "SALES"

# Optional — these are the defaults
# character_set  = "AL32UTF8"
# ncharacter_set = "AL16UTF16"
# db_unique_name = ""
# sid_prefix     = ""

# Create a PDB at the same time. Leave empty and use the pdb template instead,
# which keeps each PDB independently manageable.
# initial_pdb_name = "SALESAPP"

# auto_backup_enabled     = true
# auto_backup_window      = "SLOT_TWO"
# recovery_window_in_days = 30
