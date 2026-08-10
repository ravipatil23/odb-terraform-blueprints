variable "name" {
  description = "Anchor name."
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group this anchor maps to an OCI compartment."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
