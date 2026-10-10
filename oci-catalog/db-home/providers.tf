# Terraform and provider requirements are placed in this file.

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 6.0.0"
    }
  }
}

# Auth comes from ~/.oci/config or OCI_* env vars — no secrets in this code.
provider "oci" {
  region = var.oci_region
}
