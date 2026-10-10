variable "region" {
  type        = string
  description = "OCI region holding the DNS Hub and every VM cluster VCN it serves, e.g. \"us-ashburn-1\". Same-region only - the hub links to each VCN with an LPG pair, and LPG peering does not cross regions. For databases in several regions, run one hub per region."
}

variable "compartment_id" {
  type        = string
  description = "OCID of the compartment holding the VCNs, LPGs and DNS objects."
}

# ── DNS Hub VCN (Network Anchor) ─────────────────────────────────────────────

variable "hub_vcn_id" {
  type        = string
  description = "OCID of the central DNS Hub VCN."
}

variable "hub_resolver_id" {
  type        = string
  default     = null
  description = "OCID of the Hub VCN system resolver. Discovered from the VCN when null."
}

variable "create_hub_listening_endpoint" {
  type        = bool
  default     = true
  description = "Create the hub LISTENING endpoint here. The hub's Network Anchor must be created with isOracleDnsListeningEndpointEnabled = false (db-at-azure's network-anchor module: dns_listening_endpoint_enabled, default false), so this configuration owns the listener - in a resolver subnet it is given, answering from every environment's attached views. Set false only for a hub whose anchor was already built with that flag on; the address is then supplied or discovered instead."
}

variable "hub_resolver_subnet_id" {
  type        = string
  default     = null
  description = "OCID of the Hub VCN subnet that hosts the LISTENING endpoint - the subnet whose CIDR is hub_resolver_subnet_cidr. Required when create_hub_listening_endpoint is true; unused otherwise."
}

variable "hub_listening_endpoint_name" {
  type        = string
  default     = "dnsHubListener"
  description = "Name of the hub LISTENING endpoint. Must be unique within the hub resolver; alphanumeric, starting with a letter. Renaming replaces the endpoint, which changes its address unless hub_listening_endpoint_ip pins one."
}

variable "hub_listening_endpoint_ip" {
  type        = string
  default     = null
  description = "Private IP of the hub LISTENING endpoint - the address each VM cluster VCN forwards to, and the one Azure's DNS forwarding ruleset points at. When the endpoint is created here, this pins its address within hub_resolver_subnet_cidr; OCI assigns a free one when null. When it is not (create_hub_listening_endpoint = false), this overrides discovery from the hub resolver."
}

variable "hub_resolver_subnet_cidr" {
  type        = string
  description = "CIDR of the Hub resolver subnet."
}

# ── Resolver security lists ──────────────────────────────────────────────────
#
# Security lists rather than NSGs: an NSG has to be attached to the resolver
# ENDPOINTS (nsg_ids on oci_dns_resolver_endpoint), which ties every rule's
# identity to an object this configuration creates and replaces. A security list
# governs the SUBNET, so the endpoints inside it are untouched by the rules
# protecting them - and the default list is already attached to the subnet, so
# there is nothing to wire up afterwards.
#
# Port 53 is opened broadly (0.0.0.0/0), the same posture as the Network Anchor's
# own NSG. Reaching a resolver endpoint still needs a route and a peering.

variable "hub_resolver_security_list_id" {
  type        = string
  default     = null
  description = "OCID of the DEFAULT security list on the hub resolver subnet. DNS (UDP/TCP 53) ingress is written into it, broadly. AUTHORITATIVE: the declared rules become the whole list, so anything on it that is not declared here is removed - inspect it with `oci network security-list get` before the first apply. Null leaves the port-53 rules to you."
}

variable "allow_all_egress" {
  type        = bool
  default     = true
  description = "Re-state the \"all protocols to 0.0.0.0/0\" egress rule a default security list normally ships with, on every list this configuration manages. On by default because the rule set is replaced wholesale, and silently dropping egress would break outbound traffic from every subnet those lists govern. Turn it off only for lists you know carry no such rule."
}

variable "hub_lpg_limit" {
  type        = number
  default     = 10
  description = "Maximum LPGs attachable to the hub VCN - OCI's default is 10. Each environment consumes one, so this caps how many VM cluster VCNs a single hub can serve. Raise it here to match a limit increase granted by service request. Exceeding it warns at plan time; it does not block the apply."
}

# ── Hub resolver FORWARD rules ───────────────────────────────────────────────
#
# Extra rules on the hub's own resolver - e.g. forwarding an on-prem or partner
# domain to a DNS server that is not the Azure side. The per-spoke rules are not
# here: each VM cluster VCN's FORWARD rule lives on its own resolver, in
# modules/exadata-dns-link, driven by azure_forward_domains.
#
# READ THE WARNING ON preserve_unmanaged_hub_resolver_rules BEFORE USING THIS.

variable "hub_resolver_forward_rules" {
  description = <<-EOT
    Extra FORWARD rules to place on the hub resolver, keyed by a short name you
    choose. The key names the rule in this configuration only - it is not sent to
    OCI, and renaming it rewrites the rule list without touching the resolver's
    behaviour.

    Empty (the default) leaves the hub resolver's rules ENTIRELY unmanaged, which
    is the safe state: the Network Anchor writes its own forwarding rules to this
    same resolver and nothing here disturbs them.

    Adding even one rule makes Terraform authoritative over the whole list, since
    the API replaces it wholesale. preserve_unmanaged_hub_resolver_rules (default
    true) is what keeps the anchor's rules alive through that - leave it on.

    source_endpoint_name must name a FORWARDING endpoint that already exists on
    the hub resolver. On a hub that is the anchor's own forwarding endpoint,
    created by isOracleDnsForwardingEndpointEnabled - not the listening endpoint
    this configuration creates. A check block warns when the name matches no
    forwarding endpoint on the resolver.

    A rule needs at least one condition. qname_cover_conditions matches the
    queried name and is what a domain forward uses; client_address_conditions
    matches the querying client's IP. Both empty would forward everything.
  EOT

  type = map(object({
    source_endpoint_name      = string
    destination_addresses     = list(string)
    qname_cover_conditions    = optional(list(string), [])
    client_address_conditions = optional(list(string), [])
    action                    = optional(string, "FORWARD")
  }))
  default = {}

  validation {
    condition     = alltrue([for k, r in var.hub_resolver_forward_rules : r.action == "FORWARD"])
    error_message = "action must be \"FORWARD\" - it is the only action an OCI resolver rule supports."
  }

  validation {
    condition     = alltrue([for k, r in var.hub_resolver_forward_rules : length(r.destination_addresses) > 0])
    error_message = "Each rule needs at least one destination_addresses entry - the resolver to forward to."
  }

  validation {
    condition = alltrue([
      for k, r in var.hub_resolver_forward_rules :
      length(r.qname_cover_conditions) > 0 || length(r.client_address_conditions) > 0
    ])
    error_message = "Each rule needs at least one of qname_cover_conditions or client_address_conditions. A rule with neither matches every query and forwards the whole resolver."
  }

  validation {
    condition     = alltrue([for k, r in var.hub_resolver_forward_rules : trimspace(r.source_endpoint_name) != ""])
    error_message = "source_endpoint_name is required - it names the forwarding endpoint on the hub resolver that the rule fires from."
  }
}

variable "preserve_unmanaged_hub_resolver_rules" {
  type        = bool
  default     = true
  description = "Carry the hub resolver's existing rules through when hub_resolver_forward_rules puts this configuration in charge of the list. The hub resolver is SHARED with the Network Anchor, whose control plane writes the OCI-to-Azure forwarding rules there; the OCI API replaces the rule list wholesale, so declaring one rule without this would delete those. Read at plan time from the live resolver, matched against the declared rules so this configuration's own entries are not doubled, and re-sent alongside them. Set false only for a hub resolver you know carries nothing but the rules declared here - it deletes everything else on the next apply."
}

# ── Exadata environments (one entry per spoke, e.g. prod / nonprod) ──────────

variable "environments" {
  description = "Map of Exadata environments to wire to the DNS hub (key = env label). One entry per VM cluster VCN; each consumes one LPG on the hub, so the count is bounded by hub_lpg_limit."
  type = map(object({
    vcn_id               = string # Exadata VCN OCID
    resolver_subnet_id   = string # subnet hosting the forwarding endpoint
    resolver_subnet_cidr = string # CIDR of that subnet

    # DEFAULT security list on that resolver subnet. The DNS rules are written
    # into it, replacing whatever else it holds. Omit to write them yourself.
    resolver_security_list_id = optional(string)

    # OCIDs of the EXISTING private views belonging to this VM cluster VCN.
    # Not created here - they must pre-date the cluster, which is what lets the
    # service auto-populate their zones with the SCAN and VIP records. All of
    # them are attached to the hub resolver so the hub LISTENING endpoint can
    # answer Azure's queries for this environment's database hostnames.
    #
    # A list because one VCN may carry several views (e.g. split zones per
    # application). Views shared by more than one environment are deduplicated
    # before attachment.
    view_ids = list(string)

    # Set BOTH when this VCN is already peered to the hub VCN - the LPG pair is
    # then referenced, not created. OCI allows only one peering between any two
    # VCNs, so creating a second fails on connect and strands two orphaned
    # gateways against the 10-LPG-per-VCN limit. Omit both to create the pair.
    existing_hub_lpg_id     = optional(string)
    existing_exadata_lpg_id = optional(string)
  }))

  validation {
    condition = alltrue([
      for k, e in var.environments :
      (e.existing_hub_lpg_id == null) == (e.existing_exadata_lpg_id == null)
    ])
    error_message = "existing_hub_lpg_id and existing_exadata_lpg_id must be set together or both omitted. A peering has two ends; supplying one leaves the other side unresolvable."
  }
}

# ── DNS forwarding behaviour ─────────────────────────────────────────────────

variable "azure_forward_domains" {
  type        = list(string)
  default     = ["azure.com", "windows.net"]
  description = "Azure domains every environment must resolve via the hub listener."
}

