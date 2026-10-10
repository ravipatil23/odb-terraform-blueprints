variable "compartment_id" {
  type        = string
  description = "OCID of the compartment that holds the VCNs, LPGs and DNS resolver objects."
}

variable "env_name" {
  type        = string
  description = "Short environment label used in names, e.g. \"prod\" or \"nonprod\"."
}

# ── DNS Hub VCN (the Network Anchor's VCN) ───────────────────────────────────

variable "hub_vcn_id" {
  type        = string
  description = "OCID of the central DNS Hub VCN."
}

variable "hub_listening_endpoint_ip" {
  type        = string
  description = "Private IP of the DNS Hub LISTENING resolver endpoint (the hub's listener)."
}

variable "hub_resolver_subnet_cidr" {
  type        = string
  description = "CIDR of the Hub VCN subnet that hosts the DNS resolver endpoints."
}

# ── Exadata VCN (this environment's spoke) ───────────────────────────────────

variable "exadata_vcn_id" {
  type        = string
  description = "OCID of this environment's Exadata VCN."
}

# ── Existing LPG pair (optional) ─────────────────────────────────────────────
# Set both when this VCN is ALREADY peered to the hub VCN. The module then
# references that pair instead of creating one - OCI allows only one peering
# between any two VCNs, so creating a second fails on connect and strands two
# orphaned gateways against the per-VCN LPG limit.

variable "existing_hub_lpg_id" {
  type        = string
  default     = null
  description = "OCID of the hub-side LPG of an existing peering to this VCN. When set, no LPG pair is created."
}

variable "existing_exadata_lpg_id" {
  type        = string
  default     = null
  description = "OCID of this VCN's side of that existing peering. Required whenever existing_hub_lpg_id is set."
}

variable "exadata_resolver_id" {
  type        = string
  default     = null
  description = "OCID of the Exadata VCN system resolver. Discovered from the VCN when null."
}

variable "exadata_resolver_subnet_id" {
  type        = string
  description = "OCID of the Exadata VCN subnet that will host the FORWARDING resolver endpoint."
}

variable "exadata_resolver_subnet_cidr" {
  type        = string
  description = "CIDR of the Exadata resolver subnet (used in routing and DNS ingress rules)."
}

variable "exadata_resolver_security_list_id" {
  type        = string
  default     = null
  description = "OCID of the DEFAULT security list on this environment's resolver subnet. The DNS rules are written into it - egress to the hub resolver subnet, which is what the forwarding endpoint needs, plus matching ingress. AUTHORITATIVE: the declared rules become the whole list, so anything on it that is not declared here is removed. Null leaves the rules to you."
}

variable "allow_all_egress" {
  type        = bool
  default     = true
  description = "Re-state the \"all protocols to 0.0.0.0/0\" egress rule a default security list normally ships with. On by default because the rule set is replaced wholesale, and silently dropping egress would break outbound traffic from every subnet the list governs."
}

# ── DNS forwarding behaviour ─────────────────────────────────────────────────

variable "azure_forward_domains" {
  type        = list(string)
  description = "Azure domains the databases must resolve via the hub, e.g. [\"azure.com\", \"windows.net\", \"database.azure.com\"]."
  default     = ["azure.com", "windows.net"]
}

