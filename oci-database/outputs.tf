output "db_homes" {
  description = "Database Homes keyed by their db_homes map key."
  value = { for k, v in module.db_home : k => {
    db_home_id = v.db_home_id
  } }
}

output "cdbs" {
  description = "Container Databases keyed by \"<homeKey>.<cdbKey>\"."
  value = { for k, v in module.cdb : k => {
    cdb_id  = v.cdb_id
    db_name = v.db_name
  } }
}

output "pdbs" {
  description = "Pluggable Databases keyed by \"<homeKey>.<cdbKey>.<pdbKey>\"."
  value = { for k, v in module.pdb : k => {
    pdb_id   = v.pdb_id
    pdb_name = v.pdb_name
  } }
}

output "nsgs" {
  description = "Custom NSGs, keyed by nsg key. nsg_id is the handle to attach to database VNICs or a subnet in OCI — this blueprint creates the NSG but does not attach it."
  value = {
    for k, m in module.nsg : k => {
      nsg_id       = m.nsg_id
      display_name = m.display_name
      rule_ids     = m.rule_ids
    }
  }
}

output "dns_forwarders" {
  description = "DNS forwarders per key. forwarding_address is where queries leave the VCN from — allow it at the destination resolver."
  value = {
    for k, m in module.dns_forwarder : k => {
      endpoint_name      = m.endpoint_name
      forwarding_address = m.forwarding_address
      resolver_id        = m.resolver_id
      forwarded_domains  = m.forwarded_domains
    }
  }
}

output "autonomous_container_dbs" {
  description = "Autonomous Container Databases keyed by their autonomous_container_dbs map key. The capacity fields are how you tell whether another Autonomous Database still fits — the create call fails, not the plan, when a container is full."
  value = { for k, m in module.autonomous_container_db : k => {
    acd_id       = m.acd_id
    db_name      = m.db_name
    display_name = m.display_name
    db_version   = m.db_version
    state        = m.state

    total_cpus                                        = m.total_cpus
    available_cpus                                    = m.available_cpus
    reclaimable_cpus                                  = m.reclaimable_cpus
    largest_provisionable_autonomous_database_in_cpus = m.largest_provisionable_autonomous_database_in_cpus
  } }
}

output "autonomous_dbs" {
  description = "Autonomous Databases keyed by \"<acdKey>.<adbKey>\". uses_vault_secret reports whether the ADMIN password is a Vault reference (true) or a literal held in state (false)."
  value = { for k, m in module.autonomous_db : k => {
    adb_id             = m.adb_id
    db_name            = m.db_name
    display_name       = m.display_name
    acd_id             = m.acd_id
    state              = m.state
    private_endpoint   = m.private_endpoint
    uses_vault_secret  = m.uses_vault_secret
    connection_strings = m.connection_strings
  } }
}
