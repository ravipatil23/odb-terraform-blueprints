# ── Database Home ─────────────────────────────────────────────────────────────
# Creates one DB Home on an existing VM cluster.

oci_region = "us-ashburn-1"

# The cluster this home lands on. From a db-at-* blueprint:
#   terraform output -json | jq -r '.vm_clusters.value.vmc1.ocid'
vm_cluster_ocid = "ocid1.cloudvmcluster.oc1.iad.xxxx"

display_name = "home19"
db_version   = "19.28.0.0.0"
