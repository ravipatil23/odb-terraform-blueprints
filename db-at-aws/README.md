# Oracle Database@AWS — Terraform Blueprint

A complete, standalone Terraform configuration for deploying **Oracle Database@AWS**
(Oracle Exadata Database Service on AWS). You only edit [`terraform.tfvars`](terraform.tfvars) —
the `.tf` files are reusable as-is.

---

## Table of contents

1. [What this deploys](#1-what-this-deploys)
2. [Architecture](#2-architecture)
3. [Prerequisites](#3-prerequisites)
4. [Authentication](#4-authentication)
5. [Repository layout](#5-repository-layout)
6. [Quick start](#6-quick-start)
   - [Order of operations](#61-order-of-operations)
   - [Provisioning time](#62-provisioning-time)
7. [Variable reference](#7-variable-reference)
   - [Top-level](#71-top-level-variables)
   - [`aws_networks`](#72-aws_networks)
   - [`aws_infras`](#73-aws_infras)
   - [`aws_clusters`](#74-aws_clusters)
   - [`aws_peerings`](#75-aws_peerings)
   - [`aws_autonomous_clusters`](#76-aws_autonomous_clusters)
8. [How resources are wired](#8-how-resources-are-wired)
   - [Using an existing network or infrastructure](#81-using-an-existing-network-or-infrastructure)
   - [Importing existing resources](#82-importing-existing-resources)
9. [Scaling: adding more resources](#9-scaling-adding-more-resources)
10. [Outputs](#10-outputs)
11. [Day-2 operations](#11-day-2-operations)
12. [Destroying](#12-destroying)
13. [Troubleshooting](#13-troubleshooting)
14. [FAQ](#14-faq)

---

## 1. What this deploys

| Order | Resource | Terraform resource | Module |
|-------|----------|--------------------|--------|
| 1 | Exadata Infrastructure | `aws_odb_cloud_exadata_infrastructure` | `modules/exadata-infra` |
| 2 | ODB Network | `aws_odb_network` | `modules/odb-network` |
| 3 *(optional)* | Network peering | `aws_odb_network_peering_connection` | `modules/peering` |
| 4 | VM Cluster | `aws_odb_cloud_vm_cluster` | `modules/vm-cluster` |
| 4 *(optional)* | Autonomous VM Cluster | `aws_odb_cloud_autonomous_vm_cluster` | `modules/autonomous-vm-cluster` |

**Two cluster types, one infrastructure.** Both hang off the same Exadata infrastructure and ODB
network, and both take auto-discovered DB servers — but they host different things:

| Map | Cluster | Hosts | Downstream |
|-----|---------|-------|------------|
| `aws_clusters` | VM Cluster (ExaDB-D) | DB Homes → CDBs → PDBs | [`oci-database`](../oci-database) |
| `aws_autonomous_clusters` | Autonomous VM Cluster (ADB-D) | Autonomous Container Databases → Autonomous DBs | *not covered by this repo* |

Run both on one infrastructure, or only the one you need. Leave `aws_autonomous_clusters` empty and
the blueprint behaves exactly as it did before it existed.

A data source (`aws_odb_db_servers`) sits between the infrastructure and the VM cluster to
**auto-discover** the DB server IDs from the infrastructure and hand them to the cluster — you never
copy IDs by hand.

That is the **recommended operational order** — the sequence to follow and verify. Terraform does
not enforce all of it; see [§6.1](#61-order-of-operations) for what the dependency graph actually
guarantees.

**Provider:** `hashicorp/aws >= 6.42.0` · **Terraform:** `>= 1.5.0` (or OpenTofu `>= 1.6.0`).

---

## 2. Architecture

```
                          ┌─────────────────────────────────────────────┐
                          │             Your AWS account                 │
                          │                                              │
  terraform.tfvars        │   ┌────────────────────────────────────┐    │
  ┌───────────────┐       │   │  ODB Network  (modules/odb-network) │    │
  │ aws_networks   │──────┼──▶│   ├─ client subnet CIDR             │    │
  │                │      │   │   └─ backup subnet CIDR             │    │
  ├───────────────┤       │   └────────────────────────────────────┘    │
  │ aws_infras     │──────┼──▶┌────────────────────────────────────┐     │
  │                │      │   │  Exadata Infrastructure             │    │
  ├───────────────┤       │   └──────────────┬─────────────────────┘    │
  │ aws_clusters   │       │   ┌──────────────▼─────────────────────┐    │
  │                │──────┼──▶│  data.aws_odb_db_servers            │    │
  ├───────────────┤       │   │       (auto-discovery)              │    │
  │ aws_peerings   │       │   └──────────────┬─────────────────────┘    │
  │  (optional)    │──┐    │   ┌──────────────▼─────────────────────┐    │
  ├───────────────┤  │    │   │  VM Cluster (modules/vm-cluster)    │    │
  │ aws_autonomous │  │    │   └─────────────────────────────────────┘    │
  │   _clusters    │──┼───▶┌─────────────────────────────────────┐        │
  │  (optional)    │  │    │  Autonomous VM Cluster (ADB-D)      │        │
  └───────────────┘  │    │   └─────────────────────────────────────┘    │
        map keys     │    │   ┌─────────────────────────────────────┐    │
   wire everything   └────┼──▶│  Peering → your existing VPC        │    │
                          │   └─────────────────────────────────────┘    │
                          └─────────────────────────────────────────────┘
```

The maps in `terraform.tfvars` are joined by **keys**, not by IDs:

```
aws_clusters["vmc1"].network_ref             = "net1"    ─▶ aws_networks["net1"]
aws_clusters["vmc1"].infra_ref               = "infra1"  ─▶ aws_infras["infra1"]
aws_peerings["peer1"].network_ref            = "net1"    ─▶ aws_networks["net1"]
aws_autonomous_clusters["avmc1"].infra_ref   = "infra1"  ─▶ aws_infras["infra1"]   (same infra)
aws_autonomous_clusters["avmc1"].network_ref = "net1"    ─▶ aws_networks["net1"]
```

---

## 3. Prerequisites

Before `terraform apply`:

1. **Oracle Database@AWS enabled** for your account. Subscribe through AWS Marketplace
   (“Oracle Database@AWS”) and complete the Oracle/AWS account linking. This is a one-time,
   account-level step done outside Terraform.
2. **A region and AZ where ODB@AWS is offered.** You need the **availability zone ID** (e.g.
   `use1-az6`), not just the AZ name — find it with:
   ```bash
   aws ec2 describe-availability-zones --region us-east-1 \
     --query "AvailabilityZones[].{Name:ZoneName,Id:ZoneId}" --output table
   ```
3. **IAM permissions** for the `odb` service (ODB networks, Exadata infrastructure, VM clusters,
   peering) plus EC2 read access for AZ lookups, on the identity running Terraform.
4. **Service quotas / capacity** for the chosen shape in that AZ.
5. **A peer VPC** (only if you'll use `aws_peerings`) — you'll supply its `vpc-…` ID.
6. **Terraform `>= 1.5.0`** (the configuration uses optional object attributes).

---

## 4. Authentication

This blueprint uses the standard AWS credential chain — any of:

```bash
aws configure                      # writes ~/.aws/credentials
# or
export AWS_PROFILE=my-profile
# or
export AWS_ACCESS_KEY_ID=...  AWS_SECRET_ACCESS_KEY=...  AWS_SESSION_TOKEN=...
```

…or an EC2 instance role / SSO. The provider's region comes from `aws_region` in `terraform.tfvars`.
Each network/infra/cluster entry can override the region via its own `region` field.

---

## 5. Repository layout

```
db-at-aws/
├── main.tf              # provider + module wiring (do not need to edit)
├── variables.tf         # variable definitions (do not need to edit)
├── outputs.tf           # outputs (do not need to edit)
├── terraform.tfvars     # ◀── YOU EDIT THIS
└── modules/
    ├── odb-network/            # ODB network
    ├── exadata-infra/          # Exadata infrastructure
    ├── peering/                # ODB network peering (optional)
    ├── vm-cluster/             # VM cluster (ExaDB-D)
    └── autonomous-vm-cluster/  # Autonomous VM cluster (ADB-D, optional)
```

---

## 6. Quick start

```bash
cd db-at-aws

# 1. authenticate
aws configure            # or export AWS_PROFILE

# 2. edit terraform.tfvars — set aws_region, availability_zone_id, subnet CIDRs,
#    gi_version, and your real SSH public key

# 3. run
terraform init
terraform plan           # review what will be created
terraform apply
```

### 6.1 Order of operations

The recommended operational order — the sequence to follow and verify as the apply progresses:

| # | Step | Typical elapsed |
|---|------|-----------------|
| 1 | **Exadata infrastructure** — confirm it provisions and is healthy | ~15–20 min |
| 2 | **ODB network** — the long pole of the early build | up to ~4 h |
| 3 | **Peering** *(optional)* — once the network is up | ~15–20 min |
| 4 | **VM cluster** — needs both the infra and the network | ~4–8 h |
| 4 | **Autonomous VM cluster** *(optional)* — same dependencies, runs alongside | ~4–8 h |

**Terraform does not enforce steps 1 and 2 relative to each other.** The infra takes no argument from
the ODB network, so the two are independent branches the graph is free to run **concurrently**. Only
the convergence at the clusters is a real dependency:

```
exadata_infra ──▶ data.aws_odb_db_servers ──┬──▶ vm_cluster
odb_network ────────────────────────────────┼──▶ autonomous_vm_cluster (optional)
      └──▶ peering  (optional; starts once odb_network is up)
```

Both cluster types converge on the same two branches, so configuring both does not lengthen the
critical path — they build **in parallel** with each other, not one after the other.

In practice the two line up anyway: the infra finishes in ~20 minutes and the network takes hours,
so the completion order matches the table above without anything forcing it.

One `terraform apply` covers all four steps — you do not need to stage them, and you should **not**
`-target` the pieces individually. `-target`ing the infra first and the cluster after skips
`data.aws_odb_db_servers`, which is the lookup that hands the DB server IDs to the cluster.

### 6.2 Provisioning time

This apply is measured in **hours, not minutes**. Plan a window and let it run to completion.

In the operational order of [§6.1](#61-order-of-operations):

| # | Resource | Typical elapsed | Module timeout ceiling |
|---|----------|-----------------|------------------------|
| 1 | Exadata infrastructure | ~15–20 min | provider default (module sets none) |
| — | DB server discovery (data source) | seconds | — |
| 2 | **ODB network** | **up to ~4 h** | create 12h · update 2h · delete 8h |
| 3 | Peering *(optional)* | ~15–20 min | provider default (module sets none) |
| 4 | **VM cluster** | **~4–8 h** | create 12h · update 2h · delete 8h |
| | **Full apply (critical path)** | **~8–12 h** | — |

**The Exadata infrastructure is the fastest thing here, not the slowest.** The hardware provisions in
15–20 minutes; the two long poles are the **ODB network** (up to 4 h) and the **VM cluster** (4–8 h).
Budget on those two and nothing else will surprise you.

Because the network and the infra run concurrently, the critical path skips the infra entirely:

```
odb_network (≤4 h) ─────────────┬──▶ vm_cluster (4–8 h)   ≈ 8–12 h total
exadata_infra (15–20 min) ──────┘
                └──▶ peering (15–20 min, off the critical path)
```

The infra sitting "done" while the apply runs on for hours is expected — the cluster is waiting on
the network branch, not the hardware. At 8–12 hours the whole apply does not fit in a business day;
start it early or plan across two.

The two columns are different things. **Typical elapsed** comes from observed runs and is still a
range — it varies with shape, `compute_count` / `storage_count`, and current capacity in the AZ.
**Timeout ceiling** is exact: it is the `timeouts` block in that module's `main.tf`, the point at
which Terraform stops waiting and errors. It is a limit, not an estimate.

Terraform prints `Still creating... [10m0s elapsed]` the whole time; that is healthy, not a hang.
To capture your own figures:

```bash
time terraform apply -auto-approve
TF_LOG=INFO terraform apply 2>&1 | grep -E "Creation complete|Still creating"
```

Destroying is no faster — delete ceilings are 8h on both the network and the cluster. And because
every VM cluster argument is ForceNew, a change Terraform cannot apply in place proposes
**replacement**, paying the multi-hour cluster build again — see [§11](#11-day-2-operations).

---

## 7. Variable reference

### 7.1 Top-level variables

| Variable | Type | Required | Description |
|----------|------|----------|-------------|
| `aws_region` | string | ✅ | Default AWS region for the deployment. Overridable per map entry via `region`. |
| `tags` | map(string) | — | Tags applied to all resources. Default `{}`. |
| `existing_odb_network_ids` | map(string) | — | IDs of ODB networks that already exist, keyed the way `network_ref` references them. Referenced only, never created. See [8.1](#81-using-an-existing-network-or-infrastructure). |
| `existing_infra_ids` | map(string) | — | IDs of Exadata infrastructures that already exist, keyed the way `infra_ref` references them. Referenced only, never created. See [8.1](#81-using-an-existing-network-or-infrastructure). |

### 7.2 `aws_networks`

Map of ODB networks. The map **key** is referenced by `aws_clusters[*].network_ref` and
`aws_peerings[*].network_ref`.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `display_name` | string | — (required) | Friendly name for the ODB network. |
| `availability_zone_id` | string | — (required) | AZ **ID** (e.g. `use1-az6`) where the network lives. |
| `client_subnet_cidr` | string | — (required) | CIDR for the client subnet. |
| `backup_subnet_cidr` | string | — (required) | CIDR for the backup subnet. |
| `s3_access` | string | `ENABLED` | `ENABLED` or `DISABLED`. |
| `zero_etl_access` | string | `DISABLED` | `ENABLED` or `DISABLED`. |
| `sts_access` | string | `""` (unset) | `ENABLED` or `DISABLED`. Amazon STS reachability from the ODB network, via a service endpoint on the client subnet — what an Exadata VM uses to assume an IAM role and get temporary credentials (e.g. for RMAN backups to S3 or `DBMS_CLOUD` calls without stored keys). Leave blank to accept whatever the service assigned: the field is `Optional + Computed`, so a blank never diffs. |
| `kms_access` | string | `""` (unset) | `ENABLED` or `DISABLED`. AWS KMS reachability from the ODB network, via a service endpoint on the client subnet — what the database calls to unwrap a TDE master key held in KMS rather than in a local wallet. Needed on every startup and on key rotation, not just at setup. Blank accepts whatever the service assigned; `Optional + Computed`, so it never diffs. |
| `s3_policy_document` | string | `""` | Endpoint policy (JSON) for the S3 endpoint. Only meaningful while `s3_access = "ENABLED"`. |
| `sts_policy_document` | string | `""` | Endpoint policy (JSON) for the STS endpoint — scope which roles the network may assume. Only meaningful while `sts_access = "ENABLED"`; see the example below. |
| `kms_policy_document` | string | `""` | Endpoint policy (JSON) for the KMS endpoint — scope which keys and which crypto operations the network may use. Only meaningful while `kms_access = "ENABLED"`; see the example below. |
| `cross_region_s3_restore_sources_access` | set(string) | `[]` | Regions enabled as cross-region S3 restore sources (e.g. `["us-west-2"]`). |
| `availability_zone` | string | `""` | AZ name override (usually leave blank; use the ID above). |
| `region` | string | `""` | Region override. |
| `custom_domain_name` | string | `""` | Custom DNS domain — mutually exclusive with `default_dns_prefix`. |
| `default_dns_prefix` | string | `""` | DNS prefix — used only when `custom_domain_name` is blank. |
| `delete_associated_resources` | bool | `false` | Delete associated resources on network deletion. |

**Service access from the ODB network.** `s3_access`, `sts_access`, `kms_access` and
`zero_etl_access` each place (or withhold) a managed AWS service endpoint on the network's client
subnet. The Exadata VMs have no route to the public internet, so a service is reachable only while
its flag is `ENABLED`. `sts_access` is the one that turns on role assumption: with it enabled a
database can call `sts:AssumeRole` and work with temporary credentials — the usual pairing is
`sts_access` + `s3_access` for RMAN backups or `DBMS_CLOUD` to a bucket with no long-lived access
keys in the database.

`kms_access` is what lets the database keep its **TDE master key in AWS KMS** instead of a local
wallet. The difference from the other flags is when it is needed: the database unwraps the master key
through this endpoint on every startup and on every rotation, so KMS is on the availability path, not
just the provisioning path. Treat `DISABLED` on a network whose databases hold KMS-backed TDE keys as
an outage, not a config tidy-up. If the key is a **customer-managed CMK in another account**, its own
key policy has to allow the role too — the endpoint policy here only governs what passes through the
network's endpoint.

`sts_access` and `kms_access` are `Optional + Computed` in the provider, so leaving them blank
adopts whatever the service assigned and reports no drift. Set them explicitly only when you want
Terraform to own the value — and note that flipping one to `DISABLED` cuts off any database already
relying on it.

The endpoint policy narrows what the endpoint permits, on top of the IAM role's own policy:

```hcl
aws_networks = {
  net1 = {
    display_name         = "odbnet-prod-use1"
    availability_zone_id = "use1-az6"
    client_subnet_cidr   = "10.10.0.0/24"
    backup_subnet_cidr   = "10.10.1.0/24"

    s3_access  = "ENABLED"
    sts_access = "ENABLED"
    kms_access = "ENABLED"

    # Only this one role may be assumed through the network's STS endpoint.
    sts_policy_document = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect    = "Allow"
        Principal = "*"
        Action    = "sts:AssumeRole"
        Resource  = "arn:aws:iam::123456789012:role/odb-backup-role"
      }]
    })

    # Only TDE operations, and only against the one CMK. Deliberately omits
    # kms:ScheduleKeyDeletion and kms:DisableKey - nothing on the database side
    # needs them, and they are the two calls that lose the data.
    kms_policy_document = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect    = "Allow"
        Principal = "*"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "arn:aws:kms:us-east-1:123456789012:key/abcd1234-..."
      }]
    })
  }
}
```

A policy document on its own does nothing — without the matching flag `ENABLED` there is no endpoint
for it to attach to. The role itself (and its trust policy) lives outside this blueprint; only the
network-side reachability is managed here.

### 7.3 `aws_infras`

Map of Exadata infrastructures. The map **key** is referenced by `aws_clusters[*].infra_ref`.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `display_name` | string | — (required) | Friendly name. |
| `availability_zone_id` | string | — (required) | AZ ID — should match the network's AZ. |
| `shape` | string | `Exadata.X11M` | Exadata shape. |
| `compute_count` | number | `2` | Compute nodes. |
| `storage_count` | number | `3` | Storage servers. |
| `availability_zone` / `region` | string | `""` | Overrides. |
| `database_server_type` / `storage_server_type` | string | `""` | Optional server-type pins. |
| `customer_contacts` | list(string) | `[]` | Emails sent to OCI for notifications. |
| `mw_preference` | string | `NO_PREFERENCE` | Maintenance-window preference. |
| `mw_patching_mode` | string | `ROLLING` | `ROLLING` or `NON_ROLLING`. |
| `mw_is_custom_action_timeout_enabled` | bool | `false` | Enable custom action timeout. |
| `mw_custom_action_timeout_in_mins` | number | `15` | Custom action timeout. |
| `mw_lead_time_in_weeks` | number | `0` | Lead time in weeks (0 → unset). |
| `mw_days_of_week` / `mw_months` | list(string) | `[]` | Custom-window days/months. |
| `mw_hours_of_day` / `mw_weeks_of_month` | list(number) | `[]` | Custom-window hours/weeks. |

### 7.4 `aws_clusters`

Map of VM clusters. `infra_ref` and `network_ref` must match keys in `aws_infras` / `aws_networks`.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `display_name` | string | — (required) | Friendly name. |
| `gi_version` | string | — (required) | Grid Infrastructure version (e.g. `23.0.0.0`). |
| `hostname_prefix` | string | — (required) | Hostname prefix for cluster nodes. |
| `infra_ref` | string | — (required) | Key into `aws_infras`. |
| `network_ref` | string | — (required) | Key into `aws_networks`. |
| `cpu_core_count` | number | `16` | Enabled CPU cores. |
| `license_model` | string | `LICENSE_INCLUDED` | or `BRING_YOUR_OWN_LICENSE`. |
| `ssh_public_keys` | list(string) | `[]` | SSH keys for node access (set this!). |
| `db_servers` | list(string) | `[]` | Explicit DB server IDs (manual mode only). |
| `db_servers_mode` | string | `auto` | `auto` = discover from infra; `manual` = use `db_servers`. |
| `dco_is_diagnostics_events_enabled` | bool | `true` | Diagnostics events. |
| `dco_is_health_monitoring_enabled` | bool | `true` | Health monitoring. |
| `dco_is_incident_logs_enabled` | bool | `true` | Incident logs. |
| `cluster_name` | string | `""` | Optional cluster name. |
| `timezone` | string | `""` | e.g. `UTC`. |
| `data_storage_size_in_tbs` | number | `null` | Data storage (TB). |
| `db_node_storage_size_in_gbs` | number | `null` | Local node storage (GB). |
| `memory_size_in_gbs` | number | `null` | Memory (GB). |
| `scan_listener_port_tcp` | number | `null` | SCAN listener port. |
| `is_local_backup_enabled` | bool | `false` | Enable local backups. |
| `is_sparse_diskgroup_enabled` | bool | `false` | Enable sparse disk group. |

### 7.5 `aws_peerings`

Optional. Map of ODB network peering connections. `network_ref` must match a key in `aws_networks`.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `display_name` | string | — (required) | Friendly name. |
| `network_ref` | string | — (required) | Key into `aws_networks` (the source ODB network). |
| `peer_network_id` | string | — (required) | The **peer VPC** ID (`vpc-…`). |
| `region` | string | `""` | Region override. |

### 7.6 `aws_autonomous_clusters`

Optional. Map of **Autonomous** VM clusters (ADB-D). `infra_ref` and `network_ref` key into the same
`aws_infras` / `aws_networks` maps the ExaDB-D clusters use — both cluster types share one
infrastructure.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `display_name` | string | — (required) | Friendly name. |
| `infra_ref` | string | — (required) | Key into `aws_infras`. |
| `network_ref` | string | — (required) | Key into `aws_networks`. |
| `autonomous_data_storage_size_in_tbs` | number | — (required) | Storage for Autonomous Databases (TB). |
| `cpu_core_count_per_node` | number | — (required) | CPU cores **per node**, not per cluster. |
| `memory_per_oracle_compute_unit_in_gbs` | number | — (required) | Memory per OCPU (GB). |
| `total_container_databases` | number | — (required) | Max Autonomous Container Databases. |
| `scan_listener_port_tls` | number | `2484` | TLS SCAN listener port. |
| `scan_listener_port_non_tls` | number | `1521` | Non-TLS SCAN listener port. |
| `license_model` | string | `LICENSE_INCLUDED` | or `BRING_YOUR_OWN_LICENSE`. |
| `is_mtls_enabled_vm_cluster` | bool | `false` | Require mutual TLS. |
| `time_zone` | string | `""` | e.g. `UTC`. |
| `description` | string | `""` | Free text. |
| `db_servers` / `db_servers_mode` | list(string) / string | `[]` / `auto` | Same auto-discovery as [7.4](#74-aws_clusters), via its own data source. |
| `mw_preference` | string | `NO_PREFERENCE` | or `CUSTOM_PREFERENCE`. |
| `mw_lead_time_in_weeks` | number | `0` | 0 → unset. |
| `mw_days_of_week` / `mw_months` | list(string) | `[]` | Uppercase names, e.g. `MONDAY`, `FEBRUARY`. Validated. |
| `mw_hours_of_day` / `mw_weeks_of_month` | list(number) | `[]` | Hours 0–23, weeks 1–4. Validated. |

**The four sizing fields are required and have no defaults.** Nothing in the AWS provider schema is
marked required for this resource — an empty `aws_odb_cloud_autonomous_vm_cluster {}` passes
`terraform validate` — so the API is the only thing that would catch a missing value, hours into an
apply. The blueprint requires them at plan time instead.

**The maintenance window sits on the cluster here.** On ExaDB-D it lives on the *infrastructure*
([7.3](#73-aws_infras)), so the `mw_*` fields appear in both places and mean different things. This
one has no `patching_mode` and no custom action timeout.

**Sizing is per node / per OCPU**, not cluster totals — `cpu_core_count_per_node = 8` on a two-node
cluster is 16 cores, not 8.

---

## 8. How resources are wired

You never paste a network ID, infra ID, or DB-server ID. The root `main.tf` resolves them:

```hcl
# one keyspace for what this blueprint creates and what already exists
locals {
  odb_network_ids = merge({ for k, m in module.odb_network : k => m.network_id }, var.existing_odb_network_ids)
  infra_ids       = merge({ for k, m in module.exadata_infra : k => m.infra_id }, var.existing_infra_ids)
}

# cluster → infra ID and network ID
cloud_exadata_infrastructure_id = local.infra_ids[each.value.infra_ref]
odb_network_id                  = local.odb_network_ids[each.value.network_ref]

# cluster → DB server IDs (auto-discovered when db_servers_mode = "auto")
db_servers = each.value.db_servers_mode == "auto" ? data.aws_odb_db_servers.this[each.key].db_servers[*].id : each.value.db_servers

# peering → source ODB network ID
odb_network_id = local.odb_network_ids[each.value.network_ref]
```

That's why the only thing you set in tfvars is the **key** (`infra_ref = "infra1"`).

### 8.1 Using an existing network or infrastructure

If the ODB network or Exadata infrastructure was provisioned outside this blueprint — by hand, by
another stack, or by another team — give its **ID** under the same key your clusters already
reference, and leave the matching `aws_networks` / `aws_infras` entry out:

```hcl
existing_infra_ids = {
  infra1 = "odb-exa-0a1b2c3d4e5f67890"
}

aws_infras = {}                 # infra1 already exists — nothing to create

aws_clusters = {
  vmc1 = {
    display_name    = "vmc-prod-use1"
    gi_version      = "23.0.0.0"
    hostname_prefix = "exadb"
    infra_ref       = "infra1"  # unchanged — now resolves to the existing infra
    network_ref     = "net1"
    ssh_public_keys = ["ssh-rsa AAAA... your-key"]
  }
}
```

`existing_odb_network_ids` works the same way for `network_ref`, and peerings pick it up too.

Managed and existing resources share one keyspace, so you can mix them freely — create the network
here and reuse an existing infrastructure, or the reverse. Terraform never creates, changes or
destroys anything listed in an `existing_*` map; it only reads the ID.

Three things to know:

- Pass the **ID** (`odb-exa-…`, `odb-net-…`), not the ARN.
- Keep each resource in **one** map. Listing the same key in `aws_infras` *and*
  `existing_infra_ids` would create a new infrastructure and still wire the clusters to the
  existing one; a `check` block flags that at plan time.
- **`db_servers_mode = "auto"` works against an existing infrastructure, but read this.** The
  `aws_odb_db_servers` data source queries it by ID like any other — however it returns **every**
  server on the infrastructure, including ones existing VM clusters already hold. An infrastructure
  created outside Terraform usually *does* already host clusters, so the raw list would hand your
  new cluster servers that are taken.

  The blueprint filters that list to servers whose `vm_cluster_ids` and `autonomous_vm_cluster_ids`
  are both empty — i.e. unclaimed. If nothing is left, a `check` block names the affected clusters at
  plan time rather than letting the create fail obscurely.

  The same filter matters for a *second* cluster on an infrastructure this blueprint created: the
  first cluster claims servers, and without filtering the second would be offered them again.

If you would rather Terraform *adopt* the resource and manage it from now on, use an `import` block
instead — see [§8.2](#82-importing-existing-resources).

### 8.2 Importing existing resources

Use this when a component was provisioned outside Terraform (console, CLI, another team) and you want
Terraform to **manage** it from now on — as opposed to [§8.1](#81-using-an-existing-network-or-infrastructure),
which only references it.

The rule: **write the config to match what already exists, then import, then confirm a clean plan.**
Terraform does not generate the config from the resource; you describe reality and the import
attaches state to it.

#### The workflow

```bash
# 1. Describe the existing resource in terraform.tfvars, matching its real settings exactly
# 2. Add an import block (below) naming the module address and the resource ID
terraform plan          # ◀── must report "0 to add, 0 to change, 0 to destroy"
terraform apply         # records the import in state
# 3. Delete the import block — it has done its job
```

**A clean plan is the acceptance test.** If the plan proposes *changes*, your tfvars do not match
reality — fix the tfvars, not the resource. If it proposes *replacement*, something ForceNew
disagrees (usually `availability_zone_id`, `shape`, or a subnet CIDR); fix that before applying or
you will destroy the resource you just imported.

Here the `prevent_destroy` guards in [§12](#12-destroying) work in your favour: a replacement plan
**errors out** instead of proceeding, so a mismatched import fails loudly rather than quietly
rebuilding hours of hardware.

#### Module addresses and import IDs

Every module is `for_each`'d, so the address carries the **map key** in quotes — the same key you use
in `terraform.tfvars`:

| Resource | Import block `to` address | ID to import |
|----------|---------------------------|--------------|
| ODB network | `module.odb_network["net1"].aws_odb_network.this` | `odb-net-…` |
| Exadata infrastructure | `module.exadata_infra["infra1"].aws_odb_cloud_exadata_infrastructure.this` | `odb-exa-…` |
| VM cluster | `module.vm_cluster["vmc1"].aws_odb_cloud_vm_cluster.this` | `odb-vmc-…` |
| Peering | `module.peering["peer1"].aws_odb_network_peering_connection.this` | `odb-peer-…` |

> Pass the **ID**, not the ARN. Confirm the exact ID format against your provider version — the
> discovery commands below print the value to use verbatim.

#### Example: adopting an existing ODB network and infrastructure

```hcl
# imports.tf — delete this file once the imports have been applied

import {
  to = module.odb_network["net1"].aws_odb_network.this
  id = "odb-net-0a1b2c3d4e5f67890"
}

import {
  to = module.exadata_infra["infra1"].aws_odb_cloud_exadata_infrastructure.this
  id = "odb-exa-0a1b2c3d4e5f67890"
}
```

with the matching entries describing what is really there:

```hcl
# terraform.tfvars
aws_networks = {
  net1 = {
    display_name         = "odbnet-prod-use1"   # ← must match the real display name
    availability_zone_id = "use1-az6"
    client_subnet_cidr   = "10.10.0.0/24"       # ← must match the real CIDRs
    backup_subnet_cidr   = "10.10.1.0/24"
  }
}

aws_infras = {
  infra1 = {
    display_name         = "exa-prod-use1"
    availability_zone_id = "use1-az6"
    shape                = "Exadata.X11M"       # ← must match the real shape
    compute_count        = 2
    storage_count        = 3
  }
}
```

Clusters that already reference `network_ref = "net1"` / `infra_ref = "infra1"` need no change — the
keys now resolve to the imported resources.

#### Example: adopting a VM cluster

The cluster is the fiddliest, because several of its arguments are `ignore_changes`'d (see
[§11](#11-day-2-operations)) and its DB servers are discovered rather than set:

```hcl
import {
  to = module.vm_cluster["vmc1"].aws_odb_cloud_vm_cluster.this
  id = "odb-vmc-0a1b2c3d4e5f67890"
}
```

```hcl
aws_clusters = {
  vmc1 = {
    display_name    = "vmc-prod-use1"           # ← must match
    gi_version      = "23.0.0.0"                # ← major version as you set it
    hostname_prefix = "exadb"                   # ← the prefix, not the generated hostname
    infra_ref       = "infra1"
    network_ref     = "net1"
    cpu_core_count  = 16                        # ← must match the live core count
    ssh_public_keys = ["ssh-rsa AAAA... your-key"]
    db_servers_mode = "auto"
  }
}
```

`hostname_prefix` and `gi_version` are the usual surprises: the provider stores the *resolved* values
separately (`hostname_prefix_computed`, `gi_version_computed`), so set the **prefix and major
version you originally chose**, not what the console displays.

#### Finding the IDs

```bash
# List what exists (run `aws odb help` to confirm subcommand names for your CLI version)
aws odb list-odb-networks --region us-east-1
aws odb list-cloud-exadata-infrastructures --region us-east-1
aws odb list-cloud-vm-clusters --region us-east-1
```

Or read them off the ODB console. Once imported, `terraform output` returns them like any other
managed resource.

#### Importing several at once

Terraform **1.7+** accepts `for_each` on import blocks, which is worth it when adopting a whole
estate:

```hcl
variable "import_infra_ids" {
  type    = map(string)
  default = {} # e.g. { infra1 = "odb-exa-0a1b…", infra2 = "odb-exa-1b2c…" }
}

import {
  for_each = var.import_infra_ids
  to       = module.exadata_infra[each.key].aws_odb_cloud_exadata_infrastructure.this
  id       = each.value
}
```

On Terraform 1.5–1.6, write one static `import` block per resource instead.

#### Import or reference?

| | [§8.1](#81-using-an-existing-network-or-infrastructure) `existing_*` map | §8.2 `import` |
|---|---|---|
| Terraform manages it | No — read-only reference | **Yes** |
| Appears in `terraform destroy` | No | **Yes** |
| Config must match reality | No | **Yes**, exactly |
| Effort | Paste one ID | Describe the resource, verify a clean plan |
| Use when | Another team owns it | You are taking ownership |

Mixing is fine: import the infrastructure you own and reference the network another team runs.

---

## 9. Scaling: adding more resources

**Add a second VM cluster on the same infra/network** — just add a map entry:

```hcl
aws_clusters = {
  vmc1 = { display_name = "vmc-prod", gi_version = "23.0.0.0", hostname_prefix = "exadb", infra_ref = "infra1", network_ref = "net1", ... }
  vmc2 = {                                   # ← new
    display_name    = "vmc-reporting"
    gi_version      = "23.0.0.0"
    hostname_prefix = "rpt"
    infra_ref       = "infra1"
    network_ref     = "net1"
    cpu_core_count  = 8
    ssh_public_keys = ["ssh-rsa AAAA... your-key"]
  }
}
```

**Add a whole second stack** in another AZ/region: add a `net2` to `aws_networks`, an `infra2` to
`aws_infras`, and a `vmc3` pointing at them. No `.tf` changes — `terraform plan` shows only additions.

---

## 10. Outputs

| Output | Shape | Notes |
|--------|-------|-------|
| `odb_networks` | map keyed by network key | `network_id`, `network_arn`, and the **effective** `s3_access` / `sts_access` / `kms_access` as the service reports them |
| `exadata_infras` | map keyed by infra key | `infra_id`, `infra_arn` |
| `peerings` | map keyed by peering key | `peering_connection_id` |
| `vm_clusters` | map keyed by cluster key | `vm_cluster_id`, **`ocid`** |
| `autonomous_vm_clusters` | map keyed by autonomous cluster key | `autonomous_vm_cluster_id`, **`ocid`**, `hostname`, `domain`, `cpu_core_count`, `available_cpus` |
| `db_servers` | map keyed by cluster key | list of discovered DB server IDs |

```bash
terraform output vm_clusters
terraform output -json | jq '.vm_clusters.value.vmc1.ocid'
terraform output -json | jq '.autonomous_vm_clusters.value.avmc1.ocid'
```

The cluster **`ocid`** is the handle you feed to the `oracle/oci` provider — for a VM cluster to
create DB Homes / CDBs / PDBs ([`oci-database`](../oci-database)), for an Autonomous VM cluster to
create Autonomous Container Databases. `available_cpus` and
`available_autonomous_data_storage_size_in_tbs` are worth watching on ADB-D: they report what the
service has left unallocated, which is how you tell whether a sizing change actually took effect
given the `ignore_changes` guards.

---

## 11. Day-2 operations

- **DB server discovery:** with `db_servers_mode = "auto"`, the `data.aws_odb_db_servers` lookup runs
  on every plan and pins the current DB servers from the infra. Switch to `"manual"` and set
  `db_servers = [...]` if you need to control exactly which servers a cluster uses.
- **Auto discovery only offers *unallocated* servers.** The data source returns every server on the
  infrastructure; the blueprint filters to those with empty `vm_cluster_ids` and
  `autonomous_vm_cluster_ids`. Without that, a cluster on an infrastructure that already hosts one
  would be handed servers already in use — which is the usual state of an infrastructure adopted via
  `existing_infra_ids`, and also what a second cluster on a blueprint-created infra would hit.
  A `check` block warns at plan time if a cluster has no free servers left.
- **ExaDB-D and ADB-D compete for the same servers.** Both cluster types draw from the one
  infrastructure, so an `aws_clusters` entry and an `aws_autonomous_clusters` entry created in the
  same apply are offered the same free servers — Terraform cannot see that one will consume what the
  other was promised. Create them in separate applies, or place at least one with `"manual"`.
- **Peering CIDRs are update-only:** `peer_network_cidrs` is rejected by the AWS API on create. Create
  the peering first, then uncomment the `peer_network_cidrs` line in `modules/peering/main.tf` and the
  `peer_network_cidrs` variable, wire it through, and re-apply to manage allowed CIDRs.
- **State:** local by default. For team use, add an `backend "s3"` block to `main.tf` and re-init.
- **Drift guards on the VM cluster.** Every ODB argument is ForceNew, so drift proposes destroying
  the cluster rather than updating it. `modules/vm-cluster/main.tf` puts the fields that move
  without Terraform under `lifecycle { ignore_changes }`: `db_servers`, `cpu_core_count`,
  `memory_size_in_gbs`, `db_node_storage_size_in_gbs`, `data_storage_size_in_tbs`,
  `is_local_backup_enabled`, `is_sparse_diskgroup_enabled`, and `ssh_public_keys`. That covers
  elastic scaling from the console, key rotation on the nodes, and — with `db_servers_mode = "auto"`
  — the `data.aws_odb_db_servers` lookup returning a different set after the infra changes. To
  resize *through* Terraform, remove the relevant entry first.

- **`gi_version` is deliberately not guarded.** The AWS provider stores the resolved release
  separately and reconstructs your major version on read, so it does not drift:

  | You set | Provider exposes the resolved value as |
  |---|---|
  | `gi_version` (e.g. `19.0.0.0`) | `gi_version_computed` (the full release) |
  | `hostname_prefix` | `hostname_prefix_computed` (prefix + generated suffix) |
  | `storage_count` | `activated_storage_count` / `additional_storage_count` |

  It ships commented out in the `ignore_changes` list. Uncomment it only if a plan actually proposes
  replacement over it — find the culprit first:

  ```bash
  terraform plan -no-color | grep -B2 'forces replacement'
  ```

---

## 12. Destroying

**All five resources — ODB Network, Exadata Infrastructure, VM Cluster, Autonomous VM Cluster and Peering — are delete-protected.** Each carries
`lifecycle { prevent_destroy = true }`, so `terraform destroy` — and any plan that would replace
them — fails with an error naming the resource, rather than tearing down hardware that takes hours
to rebuild and databases that do not come back.

To remove one deliberately, delete the `lifecycle` block from that module's `main.tf`, `apply`, then
destroy:

```bash
# e.g. to allow the VM cluster to be destroyed
#   edit modules/vm-cluster/main.tf, remove the lifecycle block
terraform apply
terraform destroy
```

`prevent_destroy` only accepts a literal, so unlike the GCP blueprint's `deletion_protection` input
it cannot be toggled from `terraform.tfvars` — editing the module is the only route.

Once the blocking `lifecycle` blocks are gone, destroy order is handled automatically (peering + clusters → infra → network). If a network has
`delete_associated_resources = false` and still has dependents, remove the dependents first.

---

## 13. Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| `UnauthorizedOperation` / `AccessDenied` on `odb:*` | Missing IAM permissions for the ODB service. |
| Invalid / unsupported `availability_zone_id` | Use the AZ **ID** (`use1-az6`), not the name; confirm ODB@AWS is offered there. |
| Cluster create fails to find DB servers | Infra not finished, or `infra_ref` points at the wrong key. Check `data.aws_odb_db_servers`. |
| Peering apply rejects `peer_network_cidrs` | It's update-only — add it after the peering exists (see §11). |
| `Invalid index` on `module.exadata_infra[...]` | A cluster's `infra_ref`/`network_ref` doesn't match an existing map key. |
| Apply seems to hang for a long time | Expected — the ODB network (up to 4h) and VM cluster (4–8h) are the long poles; the infra finishes in ~20 min and then waits. See [§6.2](#62-provisioning-time). |
| `ORA-28374` / TDE key unavailable, or a database that won't open | The KMS endpoint is unreachable or the key is not permitted through it. Check the **effective** flag with `terraform output -json \| jq '.odb_networks.value.net1.kms_access'`, not the config — a blank input adopts the service value. Then check `kms_policy_document` allows `kms:Decrypt` on that key ARN, and the CMK's own key policy allows the role. |
| `AccessDenied` on `sts:AssumeRole` from inside the database | Same order: effective `sts_access`, then `sts_policy_document`, then the role's trust policy (which lives outside this blueprint). |

Validate before applying:

```bash
terraform fmt -recursive
terraform validate
```

---

## 14. FAQ

**Do I ever edit the `.tf` files?**
Only for things the maps don't expose (custom backends, enabling peering CIDRs). Routine work — more
clusters, different sizes, new AZs — is all in `terraform.tfvars`.

**Can I run this with OpenTofu?**
Yes. Replace `terraform` with `tofu`; OpenTofu resolves `hashicorp/aws` from its own registry.

**Auto vs manual DB servers — which should I use?**
`auto` is right for almost everyone: it lets the infra decide which DB servers back the cluster. Use
`manual` only when you must place a cluster on specific DB servers.

**How do I create databases (CDB/PDB) on the cluster?**
Use the cluster `ocid` output with the `oracle/oci` provider. The main Terraflow Studio app can
generate that layer; this blueprint stops at the VM cluster.

**Is the state safe to commit?**
No — `terraform.tfstate` can contain sensitive values. Use a remote backend and keep state out of git.
