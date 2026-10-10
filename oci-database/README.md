# Oracle Database (many DB Homes → many CDBs → many PDBs) — Terraform Blueprint

Standalone Terraform that creates the **database stack on existing Exadata VM cluster(s)**,
built on the natural Oracle hierarchy: **a VM cluster hosts one or more Database Homes, each
Home hosts one or more Container Databases (CDBs), and each CDB hosts one or more Pluggable
Databases (PDBs)** — and a CDB belongs to exactly one Home, a PDB to exactly one CDB. You scale
by editing **only `terraform.tfvars`** (passwords go in env vars).

> **Scope:** the VM cluster(s) must already exist. Create them first with the
> [`db-at-aws`](../db-at-aws), [`db-at-gcp`](../db-at-gcp), or [`db-at-azure`](../db-at-azure)
> blueprint (each outputs the cluster `ocid`), or use native OCI Exadata clusters.

---

## Table of contents

1. [What this deploys](#1-what-this-deploys)
2. [The model & how to scale](#2-the-model--how-to-scale)
3. [Prerequisites](#3-prerequisites)
4. [Authentication & passwords](#4-authentication--passwords)
5. [Quick start](#5-quick-start)
   - [Where this sits in the sequence](#51-where-this-sits-in-the-sequence)
   - [Order of operations and timing](#52-order-of-operations-and-timing)
6. [Variable reference](#6-variable-reference)
   - [Custom NSGs](#61-custom-nsgs)
   - [DNS forwarders](#62-dns-forwarders)
   - [Autonomous (ADB-D)](#63-autonomous-adb-d)
7. [Outputs](#7-outputs)
8. [Attaching an NSG to the VM cluster](#8-attaching-an-nsg-to-the-vm-cluster)
9. [Notes & gotchas](#9-notes--gotchas)
10. [Importing existing databases](#10-importing-existing-databases)
11. [Destroying](#11-destroying)

---

## 1. What this deploys

| Resource | Terraform resource | Module | Count |
|----------|--------------------|--------|-------|
| Database Home | `oci_database_db_home` | `modules/db-home` | one per `db_homes` entry |
| Container Database | `oci_database_database` | `modules/cdb` | one per nested `cdbs` entry |
| Pluggable Database | `oci_database_pluggable_database` | `modules/pdb` | one per nested `pdbs` entry |
| Autonomous Container Database *(optional)* | `oci_database_autonomous_container_database` | `modules/autonomous-container-db` | one per `autonomous_container_dbs` entry |
| Autonomous Database, Dedicated *(optional)* | `oci_database_autonomous_database` | `modules/autonomous-db` | one per nested `autonomous_dbs` entry |
| Network Security Group *(optional)* | `oci_core_network_security_group` + rules | `modules/nsg` | one per `nsgs` entry |
| DNS forwarder *(optional)* | `oci_dns_resolver_endpoint` + resolver `rules` | `modules/dns-forwarder` | one per `dns_forwarders` entry |

**Provider:** `oracle/oci >= 7.11.0` · **Terraform:** `>= 1.5.0` (or OpenTofu `>= 1.6.0`).

The NSGs and DNS forwarders are **independent of the database chain** — no `depends_on`, so they
apply in parallel with the homes rather than after them. Leave `nsgs` and `dns_forwarders` empty and
this blueprint behaves exactly as before.

**Two database chains, not one.** The Home/CDB/PDB rows above are the non-autonomous chain, on an
Exadata VM Cluster. The two Autonomous rows are a separate chain on an *Autonomous* VM Cluster, and
they are separate resources rather than options on the ones above — see
[§6.3](#63-autonomous-adb-d). The chains are independent: leave `autonomous_container_dbs` empty and
nothing autonomous applies, and vice versa.

The three groups cover the OCI-side essentials for a VM cluster, whichever cloud provisioned it:
databases on it, who may reach it (`nsgs`), and what it can resolve (`dns_forwarders`).

---

## 2. The model & how to scale

```
            VM cluster(s)  (var.vm_cluster_ocid, overridable per home)
                  │
        ┌─────────┴──────────┐
   Home "home19"        Home "home23"             ← db_homes map (for_each)
   (19.28.0.0.0)        (23.0.0.0)
      │                     │
  ┌───┴────┐                │
 CDB sales  CDB hr        CDB dw                  ← each home's nested cdbs map
   │          │             │
 app rpt     emp          mart                    ← each CDB's nested pdbs map
```

Everything is driven by the nested maps — **no `.tf` edits**:

```hcl
db_homes = {
  home19 = {                        # ← add a Home: new top-level key (its own db_version)
    db_version = "19.28.0.0.0"
    cdbs = {
      sales = {                     # ← add a CDB: new key under the home's cdbs
        db_name = "SALES"
        pdbs = {
          app = { pdb_name = "SALESAPP" }   # ← add a PDB: new key under the CDB's pdbs
          rpt = { pdb_name = "SALESRPT" }
        }
      }
    }
  }
  home23 = { db_version = "23.0.0.0", cdbs = { dw = { db_name = "DW", pdbs = { mart = { pdb_name = "DWMART" } } } } }
}
```

Under the hood the root flattens the tree into keyed maps — CDBs keyed `"<homeKey>.<cdbKey>"`
(e.g. `home19.sales`) and PDBs keyed `"<homeKey>.<cdbKey>.<pdbKey>"` (e.g. `home19.sales.app`) —
so each CDB is wired to its Home's `db_home_id` and each PDB to its CDB's `cdb_id` automatically.

**Multiple Homes / clusters:** each home sets its own `db_version` (e.g. a 19c home and a 23ai
home side by side). By default all homes land on the top-level `vm_cluster_ocid`; a home can set
its own `vm_cluster_ocid` to live on a different cluster.

---

## 3. Prerequisites

1. **Existing Exadata VM cluster(s)** and their **OCID(s)** (`ocid1.cloudvmcluster...`) — the
   `db-at-*` blueprints expose this as `vm_clusters[*].ocid`.
2. **IAM** to manage `database-family` in the compartment / region.
3. **Supported DB versions** for each cluster's Grid Infrastructure (e.g. `19.28.0.0.0`, `23.0.0.0`).
4. **Terraform `>= 1.5.0`** and the `oracle/oci` provider (pulled automatically).

---

## 4. Authentication & passwords

**Provider auth** comes from your OCI config — no secrets in this code:

```bash
oci setup config        # ~/.oci/config
# or export OCI_CLI_USER / OCI_CLI_TENANCY / OCI_CLI_FINGERPRINT / OCI_CLI_KEY_FILE / OCI_CLI_REGION
```

**Database passwords are NOT in tfvars.** Supply them as JSON maps via environment variables,
keyed to match the map keys (`"<home>.<cdb>"` for CDBs, `"<home>.<cdb>.<pdb>"` for PDBs):

```bash
export TF_VAR_cdb_admin_passwords='{"home19.sales":"YourStr0ng#1","home19.hr":"YourStr0ng#2","home23.dw":"YourStr0ng#3"}'
export TF_VAR_pdb_admin_passwords='{"home19.sales.app":"YourStr0ng#4","home19.sales.rpt":"YourStr0ng#5","home19.hr.emp":"YourStr0ng#6","home23.dw.mart":"YourStr0ng#7"}'
```

Oracle password rules: 9–30 chars, ≥ 2 uppercase, 2 lowercase, 2 digits, 2 special chars, and
not the DB name. A missing key surfaces as an apply-time error for that CDB/PDB.

These passwords land in Terraform state in cleartext, and there is no way around it:
`oci_database_database` takes a plain string with no secret-reference field. Treat the state file as
a credential store — encrypted remote backend, restricted access.

**Autonomous Databases are the exception.** `oci_database_autonomous_database` accepts an OCI Vault
secret OCID instead of the password, storing only the reference, so the password never enters state.
Prefer that route — see [§6.3](#63-autonomous-adb-d):

```hcl
# terraform.tfvars — an OCID is not a credential
adb_admin_password_secrets = {
  "acd1.sales" = { secret_id = "ocid1.vaultsecret.oc1.iad.xxxx" }
}
```

---

## 5. Quick start

```bash
cd oci-database

# 1. auth + passwords (keys must match the maps in terraform.tfvars)
oci setup config
export TF_VAR_cdb_admin_passwords='{"home19.sales":"...","home19.hr":"...","home23.dw":"..."}'
export TF_VAR_pdb_admin_passwords='{"home19.sales.app":"...","home19.sales.rpt":"...","home19.hr.emp":"...","home23.dw.mart":"..."}'

# 2. edit terraform.tfvars — oci_region, vm_cluster_ocid, and the db_homes tree

# 3. run
terraform init
terraform plan
terraform apply
```

### 5.1 Where this sits in the sequence

This blueprint runs **after** a VM cluster exists. It never creates one. If you provisioned with a
`db-at-*` blueprint, take the cluster OCID straight from its output:

```bash
cd ../db-at-aws                                    # or db-at-azure / db-at-gcp
terraform output -json | jq -r '.vm_clusters.value.vmc1.ocid'
# paste into this blueprint's terraform.tfvars as vm_cluster_ocid
```

For the Autonomous chain it is a **different cluster and a different variable** — an Autonomous VM
Cluster, from `db-at-aws`'s `aws_autonomous_clusters` map:

```bash
cd ../db-at-aws
terraform output -json autonomous_vm_clusters | jq -r '.avmc1.ocid'
# paste as autonomous_vm_cluster_ocid, not vm_cluster_ocid
```

### 5.2 Order of operations and timing

One `terraform apply` builds the whole stack. The chain is enforced by `depends_on` at each step —
you do not stage it:

```
db_home ──▶ cdb ──▶ pdb   (pdb optional)
nsg                       (independent — applies in parallel, if configured)
dns_forwarder             (independent — applies in parallel, if configured)
```

| Resource | Typical elapsed |
|----------|-----------------|
| DB Home + its first CDB | ~30–60+ min |
| Each additional CDB | ~15–30 min |
| Each PDB | ~10–20 min |

These are indicative — real time varies with cluster size, database version and options. None of the
three modules sets a `timeouts` block, so the `oracle/oci` provider defaults apply.

Times are **cumulative down the chain**, not parallel: a PDB cannot start until its CDB is up, which
cannot start until its DB Home is. Several homes on the same cluster do build concurrently.

Fast next to phase 1 — the `db-at-*` hardware build ahead of this is measured in **hours**, and is
the dominant cost of standing up a new environment from scratch.

---

## 6. Variable reference

| Variable | Type | Required | Description |
|----------|------|----------|-------------|
| `oci_region` | string | ✅ | OCI region of the VM cluster(s). |
| `vm_cluster_ocid` | string | ✅ | Default VM cluster OCID for homes that don't override it. |
| `db_homes` | map(object) | — | Map of DB Homes (see below). Default `{}`. |
| `cdb_admin_passwords` | map(string), sensitive (**env**) | ✅ per CDB | CDB SYS passwords keyed `"<home>.<cdb>"`. |
| `pdb_admin_passwords` | map(string), sensitive (**env**) | ✅ per PDB | PDB passwords keyed `"<home>.<cdb>.<pdb>"`. |
| `compartment_id` | string, sensitive | — | Default compartment for NSGs and for the Autonomous chain. Read when `nsgs` or `autonomous_container_dbs` is non-empty. |
| `nsgs` | map(object) | — | Custom network security groups (see [6.1](#61-custom-nsgs)). Default `{}`. |
| `dns_forwarders` | map(object) | — | Outbound DNS forwarding (see [6.2](#62-dns-forwarders)). Default `{}`. |
| `autonomous_vm_cluster_ocid` | string | — | Default **Autonomous** VM Cluster OCID for the ADB-D chain (see [6.3](#63-autonomous-adb-d)). Distinct from `vm_cluster_ocid`, which is the Exadata one. |
| `autonomous_container_dbs` | map(object) | — | Autonomous Container Databases and their nested `autonomous_dbs`. Default `{}`. |
| `adb_admin_password_secrets` | map(object) | ✅ per ADB¹ | ADB ADMIN passwords as OCI Vault secret references, keyed `"<acd>.<adb>"`. **Preferred** — stays out of state. |
| `adb_admin_passwords` | map(string), sensitive (**env**) | ✅ per ADB¹ | ADB ADMIN passwords as literals, keyed `"<acd>.<adb>"`. Lands in state in cleartext. |

¹ Exactly one of the two per database — both or neither fails the plan.

### 6.1 Custom NSGs

The VM cluster sits in an **OCI VCN** whichever cloud fronts it, so the rules controlling who can
reach the databases are OCI objects — even for clusters provisioned by `db-at-aws`, `db-at-azure` or
`db-at-gcp`. That is why they belong here rather than in a cloud blueprint.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `display_name` | string | — (required) | NSG display name. |
| `vcn_id` | string | — (required) | OCID of the VCN the VM cluster sits in. |
| `compartment_id` | string | top-level `compartment_id` | Put this NSG in a different compartment. |
| `freeform_tags` | map(string) | `{}` | Tags on the NSG. |
| `rules` | map(object) | `{}` | Security rules, keyed by a name you choose. |

**`rules` entry fields:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `direction` | string | — (required) | `INGRESS` or `EGRESS`. Decides which side below is read. |
| `protocol` | string | `"6"` | IANA number as a string — `"6"` TCP, `"17"` UDP, `"1"` ICMP, or `"all"`. |
| `source` / `source_type` | string | — / `CIDR_BLOCK` | **INGRESS only.** Required for INGRESS. |
| `destination` / `destination_type` | string | — / `CIDR_BLOCK` | **EGRESS only.** Required for EGRESS. |
| `min_port` / `max_port` | number | `null` | TCP/UDP only. Omit both for all ports; `min_port` alone for a single port. |
| `icmp_type` / `icmp_code` | number | `null` | ICMP only. |
| `description` | string | `""` | Shown on the rule in the console. |
| `stateless` | bool | `false` | Stateless rules need a matching rule in the other direction. |

```hcl
compartment_id = "ocid1.compartment.oc1..xxxx"

nsgs = {
  db_access = {
    display_name = "exadata-db-access"
    vcn_id       = "ocid1.vcn.oc1.iad.xxxx"
    rules = {
      sqlnet_from_app = { direction = "INGRESS", source = "10.20.0.0/16", min_port = 1521 }
      all_egress      = { direction = "EGRESS", protocol = "all", destination = "0.0.0.0/0" }
    }
  }
}
```

Four validations reject malformed rules at **plan** time rather than at the API: an unknown
`direction`, an INGRESS without `source` or EGRESS without `destination`, a `max_port` with no
`min_port`, and a `max_port` below `min_port`.

> **This creates the NSG; it does not attach it.** Attaching is a manual OCI CLI step against the
> VM cluster's OCID — see [§8](#8-attaching-an-nsg-to-the-vm-cluster). Until then the NSG exists but
> carries no traffic.

> **Rule keys are identity.** Renaming a key destroys and recreates that rule — a brief gap in the
> rule it enforces. Rename the `description` instead if you just want a better label.

### 6.2 DNS forwarders

Lets the databases resolve names held **outside** OCI — an on-premises zone, a corporate resolver,
another cloud's private DNS. Two pieces, both on the VM cluster's VCN resolver:

1. a **forwarding endpoint** — where queries leave the VCN from
2. **FORWARD rules** — which domains go to which resolver

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `vcn_id` | string | — (required) | VCN whose resolver gets the forwarder. |
| `subnet_id` | string | — (required) | Subnet hosting the endpoint. Must be in that VCN. |
| `endpoint_name` | string | — (required) | **Alphanumeric only** — OCI rejects hyphens, underscores and dots here. Validated. |
| `nsg_ids` | list(string) | `[]` | NSGs on the endpoint. Needs **egress on 53** to the destinations. |
| `forwarding_address` | string | `""` | Private IP for the endpoint. Auto-assigned when empty. |
| `resolver_id` | string | `null` | The VCN's resolver. Discovered from `vcn_id` when null. |
| `resolver_display_name` | string | `""` | Renames the resolver. Empty leaves the existing name — usually right, since this adopts a resolver it didn't create. |
| `rules` | map(object) | `{}` | `destination_addresses` (required), `qname_cover_conditions`, `client_address_conditions`. |

```hcl
dns_forwarders = {
  prod = {
    vcn_id        = "ocid1.vcn.oc1.iad.xxxx"
    subnet_id     = "ocid1.subnet.oc1.iad.xxxx"
    endpoint_name = "prodOnpremFwd"
    nsg_ids       = ["ocid1.networksecuritygroup.oc1.iad.xxxx"]

    rules = {
      corp = {
        qname_cover_conditions = ["corp.example.com", "ad.example.com"]
        destination_addresses  = ["10.1.1.10", "10.1.1.11"]
      }
    }
  }
}
```

> **⚠ The rules are authoritative — Terraform does not append.** The OCI API replaces the resolver's
> **entire** rule array with what you declare, so any rule already there and not listed is
> **removed** on apply. Check before the first run and bring across anything you need to keep:
>
> ```bash
> oci dns resolver get --resolver-id <ocid> --scope PRIVATE --query 'data.rules'
> ```
>
> This bites hardest on **Database@Azure**, where the Network Anchor's control plane writes
> forwarding rules to the same resolver — two writers, one array. **Database@AWS has no Network
> Anchor**, so on AWS the resolver's rules are yours alone and there is nothing to collide with.

> **First match wins, and keys are evaluated alphabetically.** OCI stops at the first rule whose
> domains match. Terraform iterates the map in key order, so with overlapping domains the *name* of
> the key decides precedence — `aaa` is evaluated before `zzz` regardless of the order you wrote
> them in. Name keys so the intended precedence falls out alphabetically.

> **A plan saying `oci_dns_resolver.this will be created` is adopting, not creating.** Resolvers are
> born with their VCN and cannot be created independently — the real operation is an update. The
> tell: `resolver_id` shows a concrete OCID while `id` is `(known after apply)`. `scope` is
> `ignore_changes`'d in the module because it is ForceNew and doesn't survive import, which would
> otherwise plan a *replacement* whose destroy half clears the rules.

**`db_homes` entry fields:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `db_version` | string | — (required) | Oracle version for this home, e.g. `19.28.0.0.0`. |
| `display_name` | string | home key | DB Home display name. |
| `vm_cluster_ocid` | string | top-level `vm_cluster_ocid` | Put this home on a different cluster. |
| `cdbs` | map(object) | `{}` | Nested map of CDBs in this home. |

**`cdbs` entry fields:** `db_name` (required, ≤ 8 alphanumeric); `character_set` / `ncharacter_set`
(`AL32UTF8` / `AL16UTF16`); `db_unique_name` / `sid_prefix` (`""`); `auto_backup_enabled` (`false`);
`auto_backup_window` / `recovery_window_in_days` (`SLOT_TWO` / `30`); `pdbs` (nested map, default `{}`).

**`pdbs` entry fields:** `pdb_name` (required, ≤ 30 chars, ≠ the CDB name).

### 6.3 Autonomous (ADB-D)

A second, independent chain. Autonomous is **not a flag** on the Home/CDB/PDB resources above — the
container and the database are different Terraform resources, and the hierarchy is one level
shallower because Autonomous has no DB Home:

```
   Autonomous VM Cluster      (var.autonomous_vm_cluster_ocid, overridable per container)
              │                created by db-at-aws/modules/autonomous-vm-cluster
              │
    ACD "acd1"   ACD "acd2"    ← autonomous_container_dbs map. The ADB-D answer to a
       │            │            Home + CDB. No admin password: Oracle runs the container.
   ┌───┴───┐        │
  sales   rpt      dw          ← each container's nested autonomous_dbs map. The answer
                                 to a PDB, and where the ADMIN password lives.
```

Keys flatten the same way as the chain above: containers keyed `"<acdKey>"`, databases keyed
`"<acdKey>.<adbKey>"` (e.g. `acd1.sales`).

**Where the cluster OCID comes from.** ADB-D needs an Autonomous VM Cluster, which this blueprint
does not create — [`db-at-aws`](../db-at-aws) does, via its `aws_autonomous_clusters` map. Take the
OCI-side OCID from its output:

```bash
cd ../db-at-aws
terraform output -json autonomous_vm_clusters | jq -r '.avmc1.ocid'
```

That `ocid` is the OCI handle, **not** the AWS id or ARN. It goes to the resource's
`cloud_autonomous_vm_cluster_id` — the Exadata Cloud / multicloud field. The provider also has a
similarly named `autonomous_vm_cluster_id`, which is the Cloud@Customer one and is not what a
Database@AWS cluster gives you; the wrong field fails on the create call, not at plan time. The
module takes only the right one, so this is a trap you can only hit by writing the resource yourself.

**Not the same as the Azure/GCP `autonomous-db` modules.** [`db-at-azure`](../db-at-azure) and
[`db-at-gcp`](../db-at-gcp) each have a module of that name, but those build Autonomous Database
**Serverless** through their native providers — Oracle runs the fleet, and there is no cluster or
container underneath. What is here is **Dedicated** (ADB-D): pinned to a container, therefore to a
cluster, therefore to the ODB network. That is also why the module takes no `subnet_id`, `nsg_ids` or
`private_endpoint_label`: those are Serverless private-endpoint fields. An ADB-D inherits its
networking from the cluster, and who may reach it is governed by the NSGs in [§6.1](#61-custom-nsgs).

#### `autonomous_container_dbs` entry fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `display_name` | string | — (required) | Friendly name for the container. |
| `cloud_autonomous_vm_cluster_ocid` | string | `""` | Put this container on a different cluster. Blank uses the top-level `autonomous_vm_cluster_ocid`. |
| `compartment_id` | string | `""` | Blank **inherits the cluster's** compartment. |
| `patch_model` | string | `RELEASE_UPDATES` | Or `RELEASE_UPDATE_REVISIONS`. |
| `db_name` | string | `""` | Max 8 alphanumeric chars. Blank lets the service generate one. |
| `db_unique_name` | string | `""` | Optional unique name. |
| `db_version` | string | `""` | Blank takes the cluster default. **Drift on this field is ignored** — see below. |
| `service_level_agreement_type` | string | `""` | `STANDARD` or `AUTONOMOUS_DATAGUARD`. Data Guard additionally needs a peer, which this module does not wire. |
| `distribution_affinity` | string | `""` | `MINIMUM_DISTRIBUTION` or `MAXIMUM_DISTRIBUTION` — how databases spread across the cluster's VMs. |
| `net_services_architecture` | string | `""` | `DEDICATED` or `SHARED` listeners. |
| `version_preference` | string | `""` | `NEXT_RELEASE_UPDATE` or `LATEST_RELEASE_UPDATE`. |
| `db_split_threshold` | number | `null` | CPU threshold for splitting a database across nodes. |
| `vm_failover_reservation` | number | `null` | Percent of capacity reserved for VM failover. `0` reserves nothing. |
| `is_dst_file_update_enabled` | bool | `null` | Apply DST timezone file updates during maintenance. |
| `kms_key_id` / `vault_id` | string | `""` | Customer-managed TDE key, and the vault holding it. Both or neither. |
| `backup_recovery_window_in_days` | number | `null` | Container backup retention. |
| `customer_contacts` | list(string) | `[]` | Emails notified about maintenance. |
| `maintenance_window` | object | `null` | `preference`, `patching_mode`, `days_of_week`, `hours_of_day`, `months`, `weeks_of_month`, `lead_time_in_weeks`, `is_monthly_patching_enabled`, custom action timeout. `null` accepts the service default. |
| `freeform_tags` / `defined_tags` | map(string) | `{}` | Tags. |
| `autonomous_dbs` | map(object) | `{}` | The databases inside this container. |

Nearly every field is **Optional + Computed** in the provider, so leaving one blank adopts whatever
the service assigns and reports no drift — the same rule as `sts_access`/`kms_access` in
[`db-at-aws`](../db-at-aws).

#### `autonomous_dbs` entry fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `db_name` | string | — (required) | Max 30 alphanumeric chars, unique among the tenancy's ADBs. |
| `display_name` | string | `""` | Falls back to `db_name`. |
| `compartment_id` | string | `""` | Falls back to the container's, then the top-level `compartment_id`. **Required** in the end — unlike the container, an ADB does not inherit one, and a plan-time precondition says so rather than letting the create fail. |
| `compute_model` | string | `ECPU` | `ECPU` (current) or `OCPU`. |
| `compute_count` | number | `null` | ECPUs. Use with `compute_model = "ECPU"`. |
| `cpu_core_count` | number | `null` | OCPUs. Use with `compute_model = "OCPU"` instead of `compute_count` — send one, not both. |
| `data_storage_size_in_tbs` | number | `null` | Storage in TB. |
| `is_auto_scaling_enabled` | bool | `null` | Compute auto-scaling, up to 3x. |
| `is_auto_scaling_for_storage_enabled` | bool | `null` | Storage auto-scaling. |
| `db_workload` | string | `OLTP` | `OLTP` or `DW`. `AJD`/`APEX` are Serverless-only shapes. |
| `db_version` | string | `""` | Blank takes the container's. Drift ignored. |
| `database_edition` | string | `""` | `STANDARD_EDITION` or `ENTERPRISE_EDITION`. |
| `license_model` | string | `""` | On ADB-D licensing is normally set on the Autonomous VM Cluster — leave blank unless this database differs. |
| `character_set` / `ncharacter_set` | string | `""` | Blank accepts `AL32UTF8` / `AL16UTF16`. |
| `in_memory_percentage` | number | `null` | Memory given to the In-Memory column store. |
| `is_mtls_connection_required` | bool | `null` | Require mutual TLS. |
| `autonomous_maintenance_schedule_type` | string | `""` | `EARLY` or `REGULAR`. |
| `kms_key_id` / `vault_id` | string | `""` | Per-database customer-managed TDE key. |
| `customer_contacts` | list(string) | `[]` | Emails notified about this database. |
| `freeform_tags` / `defined_tags` | map(string) | `{}` | Tags. |

#### The ADMIN password: Vault secret or literal

Each Autonomous Database needs **exactly one** of two routes, keyed `"<acdKey>.<adbKey>"`:

| | `adb_admin_password_secrets` *(preferred)* | `adb_admin_passwords` |
|---|---|---|
| What you supply | An OCI Vault secret OCID | The password itself |
| Provider field | `secret_id` + `secret_version_number` | `admin_password` |
| In Terraform state | **A reference only** — the password never enters state | **Cleartext.** `sensitive` hides it from CLI output, not from the state file |
| Safe in `terraform.tfvars` | Yes — an OCID is not a credential, and reading the secret needs IAM permission on the vault | No. Supply via `TF_VAR_adb_admin_passwords` |
| Rotation | Rotate in Vault. Omit `secret_version_number` to follow the current version, so no config change is needed | Re-supply the env var; `ignore_changes` means Terraform will not push it |

```hcl
# In terraform.tfvars — these are OCIDs, not secrets.
adb_admin_password_secrets = {
  "acd1.sales" = { secret_id = "ocid1.vaultsecret.oc1.iad.xxxx" }
  "acd1.rpt"   = { secret_id = "ocid1.vaultsecret.oc1.iad.yyyy", secret_version_number = 3 }
}
```

```bash
# The fallback, matching how the CDB/PDB passwords are supplied.
export TF_VAR_adb_admin_passwords='{"acd1.sales":"YourStr0ng#8"}'
```

Supplying **both** for one database, or **neither**, fails the plan on a precondition. Both is not a
harmless belt-and-braces: the provider would take the secret and ignore the literal, leaving a
cleartext password in state having achieved nothing.

This is the one place in the repo where a database password can stay out of state. The CDB/PDB
resources have no equivalent — `oci_database_database.database.admin_password` is a plain string with
no secret-reference field, so those passwords land in state whatever you do.

#### Drift and capacity

`db_version` drift is **ignored** on both the container and the database. Oracle patches Autonomous
on its own schedule, so without the guard every plan after a maintenance run would try to push the
pinned version back — and on the container that means recreating it, taking every database inside it
along.

Capacity is not checked at plan time. A container that is out of CPUs fails the ADB **create call**,
so read the container's headroom before adding databases:

```bash
terraform output -json autonomous_container_dbs | jq '.acd1 | {total_cpus, available_cpus, largest_provisionable_autonomous_database_in_cpus, reclaimable_cpus}'
```

`reclaimable_cpus` is worth knowing about: CPUs from terminated databases are not immediately back in
the pool, so a container can report low `available_cpus` shortly after a teardown.

---

## 7. Outputs

| Output | Shape |
|--------|-------|
| `db_homes` | Map keyed by home key → `{ db_home_id }`. |
| `cdbs` | Map keyed by `"<home>.<cdb>"` → `{ cdb_id, db_name }`. |
| `pdbs` | Map keyed by `"<home>.<cdb>.<pdb>"` → `{ pdb_id, pdb_name }`. |
| `nsgs` | Map keyed by nsg key → `{ nsg_id, display_name, rule_ids }`. |
| `dns_forwarders` | Map keyed by forwarder key → `{ endpoint_name, forwarding_address, resolver_id, forwarded_domains }`. |
| `autonomous_container_dbs` | Map keyed by container key → `{ acd_id, db_name, display_name, db_version, state, total_cpus, available_cpus, reclaimable_cpus, largest_provisionable_autonomous_database_in_cpus }`. |
| `autonomous_dbs` | Map keyed by `"<acd>.<adb>"` → `{ adb_id, db_name, display_name, acd_id, state, private_endpoint, uses_vault_secret, connection_strings }`. |

```bash
terraform output db_homes
terraform output -json pdbs | jq
terraform output -json nsgs | jq -r '.db_access.nsg_id'   # to attach in OCI

# Which ADB passwords are Vault references rather than literals held in state
terraform output -json autonomous_dbs | jq 'map_values(.uses_vault_secret)'
# Connection aliases, once the database reaches AVAILABLE
terraform output -json autonomous_dbs | jq -r '."acd1.sales".connection_strings.high'
```

---

## 8. Attaching an NSG to the VM cluster

Creating an NSG does not put it in the traffic path. It has to be **attached to the VM cluster**,
and that is a manual step done with the OCI CLI against the cluster's OCID.

**Why it isn't in Terraform.** No `vm-cluster` resource on AWS, Azure or GCP exposes an NSG
argument — the clusters are created through those clouds' providers, while the NSG is an OCI object.
The `oracle/oci` provider's own `oci_database_cloud_vm_cluster` does have `nsg_ids`, but adopting
the cluster into this blueprint to set it would mean taking ownership of a resource that `db-at-*`
already manages. So the attach stays a deliberate one-off.

### The two OCIDs you need

```bash
# NSG — from this blueprint
NSG=$(terraform output -json nsgs | jq -r '.db_access.nsg_id')

# VM cluster — from whichever db-at-* blueprint created it
CLUSTER=$(cd ../db-at-aws && terraform output -json | jq -r '.vm_clusters.value.vmc1.ocid')
```

### Attach — read first, then append

> **`--nsg-ids` replaces the entire list.** Oracle's own wording: *"Setting this to an empty list
> removes all resources from all NSGs."* Passing only your new NSG silently detaches every NSG
> already on the cluster. Always read the current list and append to it.

```bash
# 1. Current NSGs, so nothing is lost. `// []` covers a cluster with none attached yet.
EXISTING=$(oci db cloud-vm-cluster get --cloud-vm-cluster-id "$CLUSTER" \
  --query 'data."nsg-ids"' --raw-output)

# 2. Append and apply the combined list
oci db cloud-vm-cluster update --cloud-vm-cluster-id "$CLUSTER" --force \
  --nsg-ids "$(echo "${EXISTING:-null}" | jq -c --arg n "$NSG" '(. // []) + [$n] | unique')"
```

`--force` skips the interactive confirmation, which you want in a script and probably don't the
first time you run it by hand.

**Console alternative:** Oracle Database service → your Exadata VM cluster → **Network Security
Groups** → *Edit* → add the NSG. The console appends rather than replaces, so the read-first
concern doesn't apply there.

### The backup network

`--nsg-ids` governs the client network. The backup network has its own list, and Oracle notes it is
*"applicable only to Exadata systems"*:

```bash
oci db cloud-vm-cluster update --cloud-vm-cluster-id "$CLUSTER" --force \
  --backup-network-nsg-ids '["ocid1.networksecuritygroup...."]'
```

Same replace semantics — read and append the same way.

### Verify

```bash
oci db cloud-vm-cluster get --cloud-vm-cluster-id "$CLUSTER" --query 'data."nsg-ids"'
```

Your NSG's OCID should appear alongside any that were already there. Attachment only puts the NSG in
the path — whether traffic actually flows depends on the rules in it ([§6.1](#61-custom-nsgs)) and on
the routing between the source subnet and the cluster.

> **Terraform does not know about this attachment.** A later `terraform destroy` deletes the NSG but
> leaves the cluster referencing a deleted OCID. Detach it first — see [§11](#11-destroying).

---

## 9. Notes & gotchas

- **Hierarchy is enforced by structure:** CDBs live under a home, PDBs under a CDB — a CDB/PDB
  can't span homes. Multiple homes (e.g. different DB versions) coexist on the same cluster, or
  spread across clusters via each home's `vm_cluster_ocid`.
- **Passwords are per-entry and keyed.** CDB key = `"<home>.<cdb>"`; PDB key = `"<home>.<cdb>.<pdb>"`.
  Mismatched/missing keys fail at apply for that DB.
- **`admin_password` is under `ignore_changes`** in the CDB module — rotate it through the
  database tooling, not Terraform.
- **Renaming any map key** destroys and recreates that home/CDB/PDB (Terraform identity is the key).
  The same applies to an `autonomous_container_dbs` key — and recreating a container takes every
  Autonomous Database inside it with it.
- **Autonomous is a separate chain, not a mode.** An Autonomous Container Database and an Autonomous
  Database are their own resources on an *Autonomous* VM Cluster; nothing in `db_homes` turns
  autonomous. See [§6.3](#63-autonomous-adb-d).
- **An ACD has no admin password.** Oracle operates the container, so there is no SYS login to set —
  the ADMIN password belongs to the Autonomous Database inside it.
- **`db_version` drift is ignored on both Autonomous resources.** Oracle patches them on its own
  schedule; the guard stops every post-maintenance plan from trying to push the pinned version back.
- **Autonomous capacity is not a plan-time check.** A full container fails the ADB create call — read
  `available_cpus` from the `autonomous_container_dbs` output first.
- **OpenTofu** works — replace `terraform` with `tofu`.

---

## 10. Importing existing databases

Use this when a DB Home, CDB or PDB was created outside Terraform (OCI console, `dbaascli`, another
team) and you want Terraform to **manage** it from now on.

The rule: **write the config to match what already exists, then import, then confirm a clean plan.**
Terraform does not generate the config from the resource; you describe reality and the import
attaches state to it.

```bash
# 1. Describe the existing database in terraform.tfvars, matching its real settings exactly
# 2. Add an import block (below) naming the module address and the OCID
terraform plan          # ◀── must report "0 to add, 0 to change, 0 to destroy"
terraform apply         # records the import in state
# 3. Delete the import block — it has done its job
```

Every module is `for_each`'d, so the address carries the **map key** in quotes. CDB and PDB keys are
compound, exactly as in [§6](#6-variable-reference):

| Resource | Import block `to` address | ID to import |
|----------|---------------------------|--------------|
| DB Home | `module.db_home["home1"].oci_database_db_home.this` | DB Home OCID |
| CDB | `module.cdb["home1.cdb1"].oci_database_database.this` | Database OCID |
| PDB | `module.pdb["home1.cdb1.pdb1"].oci_database_pluggable_database.this` | PDB OCID |

```hcl
# imports.tf — delete this file once the imports have been applied

import {
  to = module.db_home["home1"].oci_database_db_home.this
  id = "ocid1.dbhome.oc1..aaaaaaaa..."
}

import {
  to = module.cdb["home1.cdb1"].oci_database_database.this
  id = "ocid1.database.oc1..aaaaaaaa..."
}

import {
  to = module.pdb["home1.cdb1.pdb1"].oci_database_pluggable_database.this
  id = "ocid1.pluggabledatabase.oc1..aaaaaaaa..."
}
```

Finding the OCIDs:

```bash
oci db db-home list --compartment-id <ocid> --vm-cluster-id <cluster-ocid>
oci db database list --compartment-id <ocid> --db-home-id <home-ocid>
oci db pluggable-database list --compartment-id <ocid> --database-id <cdb-ocid>
```

Three things specific to this blueprint:

- **Import the whole chain, or none of it.** A CDB imported without its DB Home leaves the home
  unmanaged, and the `db_home_id` wiring in `main.tf` will try to create one. Work top-down:
  home → CDB → PDB.
- **Passwords are not readable.** `admin_password` is not returned by the API, so it cannot be
  verified by the import. Set `TF_VAR_admin_password` to the database's *real* current password. The
  CDB module has `admin_password` under `ignore_changes`, so a wrong value will not show up as a
  diff — it will surface later when something tries to use it.
- **Terraform 1.7+** accepts `for_each` on import blocks if you are adopting many at once; on
  1.5–1.6, write one static block per database.

---

## 11. Destroying

```bash
terraform destroy
```

Tears down PDBs → CDBs → DB Homes (reverse dependency order). The VM cluster(s) are **not**
touched — they're inputs, owned by whatever created them.

Any Autonomous chain goes the same way, Autonomous Databases → Autonomous Container Databases, and
the Autonomous VM Cluster is likewise left alone — it belongs to `db-at-aws`. Nothing here carries
`prevent_destroy`, so **destroying a container destroys every Autonomous Database in it**. To drop
one database, remove its key from the container's `autonomous_dbs` map instead. As with the
non-autonomous chain, emptying `autonomous_container_dbs` and leaving `db_homes` alone tears down
only the Autonomous side — the chains are independent.

Any `nsgs` go too, along with their rules. They are not part of the database chain, so they are
removed independently rather than in that order. Two consequences worth knowing:

- **Detach the NSG from the VM cluster first.** Terraform has no record of the attachment made in
  [§8](#8-attaching-an-nsg-to-the-vm-cluster), so destroy deletes the NSG and leaves the cluster
  referencing a deleted OCID:

  ```bash
  EXISTING=$(oci db cloud-vm-cluster get --cloud-vm-cluster-id "$CLUSTER" --query 'data."nsg-ids"' --raw-output)
  oci db cloud-vm-cluster update --cloud-vm-cluster-id "$CLUSTER" --force \
    --nsg-ids "$(echo "$EXISTING" | jq -c --arg n "$NSG" 'map(select(. != $n))')"
  ```
- **To drop just the databases, empty `db_homes` and keep `nsgs` / `dns_forwarders`** (or the
  reverse) rather than destroying everything — the three groups are independent.

Any `dns_forwarders` go too, and destroy there is **not** symmetric with apply: the forwarding
endpoint is deleted, but the resolver survives with its **rules cleared** — the provider clears
managed properties rather than deleting a resolver it never created. Databases in that VCN stop
resolving the forwarded domains at that point.
