# Oracle Database@GCP — Terraform Blueprint

A complete, standalone Terraform configuration for deploying **Oracle Database@Google Cloud** —
both **Exadata Database Service** (Dedicated: infrastructure + VM cluster) and **Autonomous AI
Database Serverless**. You only edit [`terraform.tfvars`](terraform.tfvars) — the `.tf` files are
reusable as-is.

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
   - [`gcp_odb_networks`](#72-gcp_odb_networks)
   - [`gcp_exadata_infras`](#73-gcp_exadata_infras)
   - [`gcp_vm_clusters`](#74-gcp_vm_clusters)
   - [`gcp_odb_networks_adbs`](#75-gcp_odb_networks_adbs)
   - [`gcp_autonomous_dbs`](#76-gcp_autonomous_dbs)
8. [How resources are wired](#8-how-resources-are-wired)
   - [Importing existing resources](#81-importing-existing-resources)
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
| 1 | Exadata Infrastructure | `google_oracle_database_cloud_exadata_infrastructure` | `modules/exadata-infra` |
| 2 | ODB Network + client subnet + backup subnet | `google_oracle_database_odb_network`, `google_oracle_database_odb_subnet` ×2 | `modules/odb-network` |
| 3 | ExaDB VM Cluster | `google_oracle_database_cloud_vm_cluster` | `modules/vm-cluster` |
| — | ODB Network + client subnet *(ADB-S only, optional)* | `google_oracle_database_odb_network`, `google_oracle_database_odb_subnet` | `modules/odb-network-adbs` |
| — | Autonomous AI Database (Serverless) *(optional)* | `google_oracle_database_autonomous_database` | `modules/autonomous-db` |

A data source (`google_oracle_database_db_servers`) sits between the infrastructure and the VM
cluster to **auto-discover** the DB server OCIDs from the infrastructure and hand them to the
cluster — you never copy OCIDs by hand.

That is the **recommended operational order** — the sequence to follow and verify. Terraform does
not enforce all of it; see [§6.1](#61-order-of-operations) for what the dependency graph actually
guarantees. (This blueprint has no peering module; on AWS an optional peering step sits between the
network and the cluster.)

### Autonomous Serverless sits beside the stack, not on it

`gcp_autonomous_dbs` has no `infra_key` and no step number in the table above, because
**Serverless is not Dedicated**: Oracle runs the Exadata fleet and the database is a slice of it.
There is no Exadata Infrastructure and no VM Cluster underneath, so it is not step 3 with a fourth
bolted on — it is a parallel branch off the ODB Network.

What it shares with the rest is the network, and only part of it. An Autonomous Database attaches to
the **client subnet** and never to the backup subnet, which exists for Exadata VM Clusters alone.
That is why there are two network modules:

- **`modules/odb-network`** (`gcp_odb_networks`) — client **and** backup subnets. Use it when VM
  clusters need the network. Autonomous databases can share it too.
- **`modules/odb-network-adbs`** (`gcp_odb_networks_adbs`) — client subnet only. Use it when a
  network serves Autonomous databases alone. **A VM Cluster cannot reference one of these** — it
  needs a backup subnet, and the plan fails with `Invalid index` if you try.

It is a second module rather than a flag on the first because Terraform cannot make a resource
conditional without changing its address: a `count` on the backup subnet would rewrite
`google_oracle_database_odb_subnet.backup` to `...backup[0]` in every existing configuration — a
state move, and a proposed destroy of a live backup subnet for anyone who had already applied.

That independence cuts both ways: `gcp_exadata_infras` and `gcp_vm_clusters` can be left empty and
this blueprint deploys **only** Autonomous databases, in a fraction of the time
([§6.2](#62-provisioning-time)).

The ADMIN password is the one input that never goes in `terraform.tfvars`; it comes from
`TF_VAR_gcp_adb_admin_passwords` at apply time — see [§7.6](#76-gcp_autonomous_dbs).

**Provider:** `hashicorp/google >= 7.5.0` · **Terraform:** `>= 1.5.0` (or OpenTofu `>= 1.6.0`).

> 7.5 is the first release carrying `gcp_oracle_zone` on `google_oracle_database_odb_network`;
> 7.0 added `odb_network` / `odb_subnet` on `google_oracle_database_autonomous_database`. Provider
> requirements are static, so the floor applies whichever resources you enable. CI's **floor** job
> validates the blueprint against exactly this version.

---

## 2. Architecture

```
                          ┌─────────────────────────────────────────────┐
                          │              Your GCP project                │
                          │                                              │
  terraform.tfvars        │   ┌────────────────────────────────────┐    │
  ┌───────────────┐       │   │  ODB Network  (modules/odb-network) │    │
  │ gcp_odb_       │──────┼──▶│   ├─ client subnet  (CLIENT_SUBNET) │    │
  │   networks     │      │   │   └─ backup subnet  (BACKUP_SUBNET) │    │
  ├───────────────┤       │   └────────────────────────────────────┘    │
  │ gcp_exadata_   │──────┼──▶┌────────────────────────────────────┐     │
  │   infras       │      │   │  Exadata Infrastructure             │    │
  ├───────────────┤       │   │  (modules/exadata-infra)            │    │
  │ gcp_vm_        │       │   └──────────────┬─────────────────────┘    │
  │   clusters     │──────┼──▶┌───────────────▼─────────────────────┐    │
  └───────────────┘       │   │  data.google_oracle_database_       │    │
        map keys          │   │       db_servers  (auto-discovery)  │    │
   wire everything        │   └───────────────┬─────────────────────┘    │
                          │   ┌───────────────▼─────────────────────┐    │
                          │   │  ExaDB VM Cluster                   │    │
                          │   │  (modules/vm-cluster)               │    │
                          │   └─────────────────────────────────────┘    │
                          │                                              │
  ┌───────────────┐       │   ┌─────────────────────────────────────┐    │
  │ gcp_odb_       │──────┼──▶│  ODB Network — client subnet only    │   │
  │  networks_adbs │      │   │  (modules/odb-network-adbs)         │    │
  ├───────────────┤       │   └──────────────┬──────────────────────┘    │
  │ gcp_           │      │   ┌──────────────▼──────────────────────┐    │
  │  autonomous_dbs│──────┼──▶│  Autonomous AI DB — Serverless      │    │
  └───────────────┘       │   │  (modules/autonomous-db)            │    │
                          │   │  no infra beneath: Oracle's fleet   │    │
                          │   └─────────────────────────────────────┘    │
                          └─────────────────────────────────────────────┘
```

The maps in `terraform.tfvars` are joined by **keys**, not by IDs:

```
gcp_vm_clusters["vmc1"].network_key    = "net1"    ─▶ gcp_odb_networks["net1"]
gcp_vm_clusters["vmc1"].infra_key      = "infra1"  ─▶ gcp_exadata_infras["infra1"]
gcp_autonomous_dbs["adb1"].network_key = "net1"    ─▶ gcp_odb_networks["net1"]
                                    or = "adbnet1" ─▶ gcp_odb_networks_adbs["adbnet1"]
```

`gcp_autonomous_dbs.network_key` resolves against **either** network map — an Autonomous Database
does not care which module built its network, since both expose the same client subnet. The two maps
therefore share one keyspace, and a key defined in both is rejected before apply.

`gcp_vm_clusters.network_key` resolves against `gcp_odb_networks` only. The Autonomous branch stops
at the network: it has no `infra_key` because nothing of yours sits underneath it.

---

## 3. Prerequisites

Before `terraform apply`:

1. **An Oracle Database@Google Cloud subscription.** Subscribe through the Google Cloud Marketplace
   (“Oracle Database@Google Cloud”) and complete the Oracle/Google account linking. This is a
   one-time, account-level step done outside Terraform.
2. **Enable the API:**
   ```bash
   gcloud services enable oracledatabase.googleapis.com --project=YOUR_PROJECT
   ```
3. **A VPC network** in the project to attach the ODB network to. Note its self-link
   (`projects/PROJECT/global/networks/NAME`) — you'll set it as `network` in the tfvars.
4. **IAM permissions** on the identity running Terraform. At minimum the Oracle Database admin role
   plus the ability to read/use the VPC:
   ```bash
   gcloud projects add-iam-policy-binding YOUR_PROJECT \
     --member="user:you@example.com" \
     --role="roles/oracledatabase.admin"
   ```
   (Compute network viewer/user roles are also needed to reference the VPC.)
5. **Capacity / quota** for the chosen shape and region. Exadata capacity is region- and
   zone-specific; confirm the **Oracle zone** (e.g. `us-east4-b-r1`) is available to you.
6. **Terraform `>= 1.5.0`** (the configuration uses optional object attributes).

---

## 4. Authentication

Use Application Default Credentials (ADC):

```bash
gcloud auth application-default login
gcloud config set project YOUR_PROJECT
```

Or point at a service-account key:

```bash
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json
```

`gcp_project` and `gcp_region` in `terraform.tfvars` set the provider defaults; each map entry can
override them per-resource via its `project` / `location` fields.

---

## 5. Repository layout

```
db-at-gcp/
├── main.tf              # provider + module wiring (do not need to edit)
├── variables.tf         # variable definitions (do not need to edit)
├── outputs.tf           # outputs (do not need to edit)
├── terraform.tfvars     # ◀── YOU EDIT THIS
└── modules/
    ├── odb-network/      # ODB network + client & backup subnets
    ├── odb-network-adbs/ # ODB network + client subnet only (ADB-S; no VM clusters)
    ├── exadata-infra/    # Exadata infrastructure
    ├── vm-cluster/       # ExaDB VM cluster
    └── autonomous-db/    # Autonomous AI Database Serverless (no infra beneath)
```

---

## 6. Quick start

```bash
cd db-at-gcp

# 1. authenticate
gcloud auth application-default login

# 2. edit terraform.tfvars — set gcp_project, gcp_region, network self-link,
#    Oracle zone, CIDRs, and your real SSH public key

# 3. only if you filled in gcp_autonomous_dbs — ADMIN passwords never go in tfvars.
#    One entry per gcp_autonomous_dbs key:
export TF_VAR_gcp_adb_admin_passwords='{"adb1":"YourStr0ngPass"}'

# 4. run
terraform init
terraform plan      # review what will be created
terraform apply
```

### 6.1 Order of operations

The recommended operational order — the sequence to follow and verify as the apply progresses:

| # | Step | Typical elapsed |
|---|------|-----------------|
| 1 | **Exadata infrastructure** — confirm it provisions and is healthy | ~15–20 min |
| 2 | **ODB network** — the long pole of the early build | up to ~4 h |
| 3 | **VM cluster** — needs both the infra and the network | ~4–8 h |

**Terraform does not enforce steps 1 and 2 relative to each other.** The infra takes no argument from
the ODB network, so the two are independent branches the graph is free to run **concurrently**. Only
the convergence at the VM cluster is a real dependency:

```
exadata_infra ──▶ data.google_oracle_database_db_servers ─┬──▶ vm_cluster
odb_network ─────────────────────────────────────────────┘
    └─────────────────────────────────────────────────────────▶ autonomous_db
odb_network_adbs ────────────────────────────────────────────────┘
```

Autonomous databases hang off a network alone. They do not wait for the infrastructure or the
cluster and are built in parallel with them, so adding one to an existing stack costs nothing on the
critical path.

In practice the two line up anyway: the infra finishes in ~20 minutes and the network takes hours,
so the completion order matches the table above without anything forcing it.

One `terraform apply` covers all three steps — you do not need to stage them, and you should **not**
`-target` the pieces individually. `-target`ing the infra first and the cluster after skips the
DB-server data source, which is the lookup that hands the server OCIDs to the cluster.

### 6.2 Provisioning time

This apply is measured in **hours, not minutes**. Plan a window and let it run to completion.

In the operational order of [§6.1](#61-order-of-operations):

| # | Resource | Typical elapsed | Module timeout ceiling |
|---|----------|-----------------|------------------------|
| 1 | Exadata infrastructure | ~15–20 min | provider default (module sets none) |
| — | DB server discovery (data source) | seconds | — |
| 2 | **ODB network** | **up to ~4 h** | create 12h · update 2h · delete 8h |
| 3 | **VM cluster** | **~4–8 h** | create 12h · update 2h · delete 8h |
| | **Full apply (critical path)** | **~8–12 h** | — |

**The Exadata infrastructure is the fastest thing here, not the slowest.** The hardware provisions in
15–20 minutes; the two long poles are the **ODB network** (up to 4 h) and the **VM cluster** (4–8 h).
Budget on those two and nothing else will surprise you.

Because the network and the infra run concurrently, the critical path skips the infra entirely:
`odb_network (≤4 h) → vm_cluster (4–8 h)` ≈ **8–12 h total**. The infra sitting "done" while the
apply runs on for hours is expected — the cluster is waiting on the network branch, not the
hardware. At 8–12 hours the whole apply does not fit in a business day; start it early or plan
across two.

The two columns are different things. **Typical elapsed** comes from observed runs and is still a
range — it varies with shape, node counts, region and current capacity. **Timeout ceiling** is
exact: it is the `timeouts` block in that module's `main.tf`, the point at which Terraform stops
waiting and errors. It is a limit, not an estimate.

Terraform prints `Still creating... [10m0s elapsed]` the whole time; that is healthy, not a hang.
To capture your own figures:

```bash
time terraform apply -auto-approve
TF_LOG=INFO terraform apply 2>&1 | grep -E "Creation complete|Still creating"
```

Destroying is no faster — delete ceilings are 8h on both the network and the cluster. Unlike AWS and
Azure, tear-down here is gated by the `deletion_protection` input rather than `prevent_destroy`, so
it is togglable from `terraform.tfvars` — see [§12](#12-destroying).

---

## 7. Variable reference

### 7.1 Top-level variables

| Variable | Type | Required | Description |
|----------|------|----------|-------------|
| `gcp_project` | string | ✅ | Default project ID. Overridable per map entry via `project`. |
| `gcp_region`  | string | ✅ | Default region (e.g. `us-east4`). Overridable per map entry via `location`. |
| `gcp_adb_admin_passwords` | map(string), sensitive | — | ADMIN password per `gcp_autonomous_dbs` key. **Never put this in `terraform.tfvars`** — export `TF_VAR_gcp_adb_admin_passwords`. Default `{}`. |

The map variables that drive everything else — `gcp_odb_networks`, `gcp_odb_networks_adbs`,
`gcp_exadata_infras`, `gcp_vm_clusters`, `gcp_autonomous_dbs` — all default to `{}` and are
documented in the sections below.

### 7.2 `gcp_odb_networks`

Map of ODB networks. Each entry also creates a **client** and a **backup** subnet.
The map **key** is referenced by `gcp_vm_clusters[*].network_key` and, optionally, by
`gcp_autonomous_dbs[*].network_key` — one network can serve both, since an Autonomous Database uses
the client subnet and simply ignores the backup one.

For a network that serves Autonomous databases **only**, use
[`gcp_odb_networks_adbs`](#75-gcp_odb_networks_adbs) instead and skip the backup subnet entirely.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `odb_network_id` | string | — (required) | Unique network ID. Starts with a letter, ≤ 63 chars. |
| `network` | string | — (required) | VPC self-link: `projects/{project}/global/networks/{name}`. |
| `client_subnet_id` | string | — (required) | ID for the client subnet (lowercase letters/numbers/hyphens, ≤ 63 chars). |
| `client_cidr_range` | string | — (required) | Client CIDR. RFC1918, **/27 min, /22 max**. |
| `backup_subnet_id` | string | — (required) | ID for the backup subnet. |
| `backup_cidr_range` | string | — (required) | Backup CIDR. RFC1918, /27 min. Must **not** overlap the client CIDR. |
| `location` | string | `gcp_region` | Region override. |
| `project` | string | `gcp_project` | Project override. |
| `gcp_oracle_zone` | string | `""` | Oracle zone within the region, e.g. `us-east4-b-r1`. |
| `deletion_protection` | bool | `true` | Block deletion until set to `false`. |
| `labels` | map(string) | `{}` | Resource labels. |

### 7.3 `gcp_exadata_infras`

Map of Exadata infrastructures. The map **key** is referenced by `gcp_vm_clusters[*].infra_key`.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `cloud_exadata_infrastructure_id` | string | — (required) | Immutable unique ID. |
| `shape` | string | — (required) | `Exadata.X9M`, `Exadata.X10M`, or `Exadata.X11M`. |
| `compute_count` | number | — (required) | Compute nodes (2–32). |
| `storage_count` | number | — (required) | Storage servers (3–64). |
| `display_name` | string | `""` | Friendly name. |
| `gcp_oracle_zone` | string | `""` | Oracle zone, e.g. `us-east4-b-r1`. |
| `location` / `project` | string | region/project | Per-resource overrides. |
| `total_storage_size_gb` | number | `0` | `0`/null → shape default. |
| `customer_contacts` | list(string) | `[]` | Emails for maintenance notifications. |
| `mw_preference` | string | `NO_PREFERENCE` | `NO_PREFERENCE` or `CUSTOM_PREFERENCE`. |
| `mw_patching_mode` | string | `ROLLING` | `ROLLING` or `NONROLLING`. |
| `mw_is_custom_action_timeout_enabled` | bool | `false` | Enable custom action timeout. |
| `mw_custom_action_timeout_mins` | number | `15` | Custom action timeout. |
| `mw_lead_time_week` | number | `null` | Lead time in weeks. |
| `mw_days_of_week` / `mw_months` | list(string) | `[]` | Custom-window days/months. |
| `mw_hours_of_day` / `mw_weeks_of_month` | list(number) | `[]` | Custom-window hours/weeks. |
| `deletion_protection` | bool | `true` | Block deletion until `false`. |
| `labels` | map(string) | `{}` | Resource labels. |

> **Note:** `compute_count` and `storage_count` are under `lifecycle { ignore_changes }` in the
> module, so elastic scaling done outside Terraform won't trigger a destroy/recreate.

### 7.4 `gcp_vm_clusters`

Map of ExaDB VM clusters. `infra_key` and `network_key` must match keys in the two maps above.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `infra_key` | string | — (required) | Key into `gcp_exadata_infras`. |
| `network_key` | string | — (required) | Key into `gcp_odb_networks`. |
| `cloud_vm_cluster_id` | string | — (required) | Immutable unique ID. |
| `hostname_prefix` | string | — (required) | ≤ 12 chars, starts with a letter. |
| `cpu_core_count` | number | — (required) | Enabled CPU cores. |
| `memory_size_gb` | number | — (required) | Memory per node (GB). |
| `db_node_storage_size_gb` | number | — (required) | Local node storage per node (GB). |
| `data_storage_size_tb` | number | — (required) | Data storage (TB). |
| `ssh_public_keys` | list(string) | — (required) | SSH keys for node access. |
| `display_name` | string | `""` | Defaults to the cluster ID. |
| `location` / `project` | string | region/project | Per-resource overrides. |
| `gi_version` | string | `23.0.0.0` | Grid Infrastructure version. |
| `license_type` | string | `LICENSE_INCLUDED` | or `BRING_YOUR_OWN_LICENSE`. |
| `local_backup_enabled` | bool | `false` | Enable local backups. |
| `sparse_diskgroup_enabled` | bool | `false` | Enable sparse disk group. |
| `cluster_name` | string | `null` | Optional cluster name, ≤ 11 chars. |
| `node_count` | number | `null` | Number of nodes. |
| `ocpu_count` | number | `null` | Fractional OCPU allocation. |
| `disk_redundancy` | string | `null` | `HIGH` or `NORMAL`. |
| `time_zone` | string | `UTC` | e.g. `America/New_York`. |
| `scan_listener_port_tcp` | number | `null` | Default 1521, range 1024–8999. |
| `dco_diagnostics` / `dco_health` / `dco_incident_logs` | bool | `true` | Diagnostics collection toggles. |
| `deletion_protection` | bool | `true` | Block deletion until `false`. |
| `labels` | map(string) | `{}` | Resource labels. |

### 7.5 `gcp_odb_networks_adbs`

Map of ODB networks with a **client subnet only**. Identical to
[`gcp_odb_networks`](#72-gcp_odb_networks) minus `backup_subnet_id` and `backup_cidr_range`, because
an Autonomous Database never uses a backup subnet.

The map **key** is referenced by `gcp_autonomous_dbs[*].network_key`. **`gcp_vm_clusters` cannot
reference these** — a VM cluster needs a backup subnet, and pointing one here fails the plan with
`Invalid index` naming the key.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `odb_network_id` | string | — (required) | Unique network ID. Starts with a letter, ≤ 63 chars. |
| `network` | string | — (required) | VPC self-link: `projects/{project}/global/networks/{name}`. |
| `client_subnet_id` | string | — (required) | ID for the client subnet. |
| `client_cidr_range` | string | — (required) | Client CIDR. RFC1918, **/27 min, /22 max**. |
| `location` | string | `gcp_region` | Region override. |
| `project` | string | `gcp_project` | Project override. |
| `gcp_oracle_zone` | string | empty | Oracle zone within the region, e.g. `us-east4-b-r1`. |
| `deletion_protection` | bool | `true` | Block deletion until set to `false`. |
| `labels` | map(string) | `{}` | Resource labels. |

**The two network maps share one keyspace.** `gcp_autonomous_dbs[*].network_key` is resolved against
a merge of both, so a key present in both maps would build two networks and silently bind the
database to the ADB-S one — `merge()` takes the later value. A `check` block rejects that before
apply, naming the duplicate keys.

Reach for this map only when a network genuinely serves Autonomous databases alone. Sharing a
`gcp_odb_networks` entry with your VM clusters is equally valid and one resource fewer.

### 7.6 `gcp_autonomous_dbs`

Map of **Autonomous AI Database Serverless** instances. There is no `infra_key` — see
[§1](#autonomous-serverless-sits-beside-the-stack-not-on-it). `network_key` must match a key in
**either** network map.

Unlike infrastructures, clusters and subnets, an Autonomous Database is **regional**: it takes no
`gcp_oracle_zone`.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `autonomous_database_id` | string | — (required) | Immutable unique ID. Lowercase letters, digits, hyphens; ≤ 63 chars. |
| `database` | string | — (required) | Oracle database name. Starts with a letter, ≤ 30 alphanumeric chars. |
| `network_key` | string | — (required) | Key into `gcp_odb_networks` **or** `gcp_odb_networks_adbs`. |
| `display_name` | string | empty | Falls back to `autonomous_database_id`. |
| `location` / `project` | string | region/project | Per-resource overrides. |
| `db_workload` | string | `OLTP` | `OLTP` (transaction processing), `DW` (data warehouse), `AJD` (JSON) or `APEX`. |
| `license_type` | string | `LICENSE_INCLUDED` | or `BRING_YOUR_OWN_LICENSE`. |
| `db_edition` | string | `ENTERPRISE_EDITION` | or `STANDARD_EDITION`. |
| `db_version` | string | `23ai` | `19c` or `23ai`. Deliberately unvalidated — a newer release is a tfvars edit, not a code change. |
| `compute_count` | number | `2` | ECPUs. Minimum 2; fractional values allowed. |
| `data_storage_size_gb` | number | `120` | Storage in **GB** (the Azure blueprint sizes in TB). |
| `is_auto_scaling_enabled` | bool | `true` | Let compute scale up to **3x** the base count on demand. |
| `is_storage_auto_scaling_enabled` | bool | `false` | Let storage grow past the reserved size. |
| `backup_retention_period_days` | number | `60` | Automatic backup retention, 1–60. |
| `maintenance_schedule_type` | string | `REGULAR` | `EARLY` applies patches a week ahead of `REGULAR`. |
| `character_set` | string | `AL32UTF8` | Database character set. |
| `n_character_set` | string | `AL16UTF16` | NCHAR character set. |
| `operations_insights_state` | string | `NOT_ENABLED` | or `ENABLED`. |
| `mtls_connection_required` | bool | `true` | Require mutual TLS. `false` allows TLS-only clients. |
| `private_endpoint_label` | string | empty | Hostname prefix for the private endpoint. Empty means Oracle picks one. |
| `private_endpoint_ip` | string | empty | Must sit inside the network's `client_cidr_range`. Empty means Oracle picks one. |
| `customer_contacts` | list(string) | `[]` | Email addresses Oracle notifies about this database. |
| `deletion_protection` | bool | `true` | Block deletion until set to `false`. |
| `labels` | map(string) | `{}` | Resource labels. |

#### Eight fields are guarded and will not plan

`modules/autonomous-db` carries an `ignore_changes` block covering `compute_count`,
`data_storage_size_gb`, `data_storage_size_tb`, `db_version`, `db_edition`,
`is_auto_scaling_enabled`, `is_storage_auto_scaling_enabled` and `backup_retention_period_days` —
the list Oracle publishes for ADB@GCP.

Autonomous scaling rewrites those values in place. Without the guard, the first plan after the
service scaled would propose shrinking the database back to its seed size. **The consequence is that
editing any of them in `terraform.tfvars` produces no plan at all.** To resize deliberately, comment
the field out of that `lifecycle` block, apply, then restore it.

This is the sharpest difference from the Azure blueprint, where Autonomous resizing is a plain
in-place update.

#### The ADMIN password

The provider requires an ADMIN password, and it is the one input this blueprint refuses to read from
`terraform.tfvars`. It comes from a separate **sensitive map**, `gcp_adb_admin_passwords`, keyed by
the same key as the database:

```bash
export TF_VAR_gcp_adb_admin_passwords='{"adb1":"YourStr0ngPass","adb2":"An0therStr0ng"}'
```

```powershell
$env:TF_VAR_gcp_adb_admin_passwords = '{"adb1":"YourStr0ngPass"}'
```

Oracle's rules: **12–30 characters**, at least one uppercase, one lowercase and one digit, no double
quote, and it may not contain the word `admin`.

Miss a key and the plan stops with `Invalid index` on `var.gcp_adb_admin_passwords`, naming the
database it could not find a password for. A `check` block reports the same thing in plainer words
first. The passwords themselves are never printed: the variable is `sensitive`, and only the map's
**key names** are unwrapped to build that message.

> The password is written to state. Use a remote backend with encryption at rest — see
> [§11](#11-day-2-operations).

---

## 8. How resources are wired

You never paste a network name, infra self-link, or DB-server OCID. The root `main.tf` resolves them:

```hcl
# cluster → infra self-link (from the infra module output)
exadata_infrastructure = module.exadata_infra[each.value.infra_key].infra_self_link

# cluster → network + subnet names (from the network module outputs)
odb_network       = module.odb_network[each.value.network_key].odb_network_name
odb_subnet        = module.odb_network[each.value.network_key].client_subnet_name
backup_odb_subnet = module.odb_network[each.value.network_key].backup_subnet_name

# cluster → DB server OCIDs (auto-discovered from the infra)
db_server_ocids = data.google_oracle_database_db_servers.this[each.key].db_servers[*].properties[0].ocid

# autonomous DB → network + client subnet, from EITHER network map. A local
# merges both into one lookup, so the database does not care which module built
# its network. No backup_odb_subnet: Serverless never uses one.
odb_network = local.adb_odb_networks[each.value.network_key].odb_network_name
odb_subnet  = local.adb_odb_networks[each.value.network_key].client_subnet_name
```

That's why the only thing you set in tfvars is the **key** (`infra_key = "infra1"`).

The merge is a `local` rather than a conditional because both branches of a `?:` are evaluated in
Terraform — indexing a module for a key that was never created fails even on the branch that is not
taken.

### 8.1 Importing existing resources

Use this when a component was provisioned outside Terraform (console, `gcloud`, another team) and you
want Terraform to **manage** it from now on.

The rule: **write the config to match what already exists, then import, then confirm a clean plan.**
Terraform does not generate the config from the resource; you describe reality and the import
attaches state to it.

#### The workflow

```bash
# 1. Describe the existing resource in terraform.tfvars, matching its real settings exactly
# 2. Add an import block (below) naming the module address and the resource name
terraform plan          # ◀── must report "0 to add, 0 to change, 0 to destroy"
terraform apply         # records the import in state
# 3. Delete the import block — it has done its job
```

**A clean plan is the acceptance test.** If the plan proposes *changes*, your tfvars do not match
reality — fix the tfvars, not the resource. If it proposes *replacement*, something ForceNew
disagrees (usually `gcp_oracle_zone`, `shape`, or a CIDR); fix that before applying or you will
destroy the resource you just imported. Note that `deletion_protection` defaults to `true` here
(see [§12](#12-destroying)), which blocks the destroy half of a replacement.

#### Module addresses and import IDs

Every module is `for_each`'d, so the address carries the **map key** in quotes — the same key you use
in `terraform.tfvars`. Google resources import by their full resource name:

| Resource | Import block `to` address | ID to import |
|----------|---------------------------|--------------|
| ODB network | `module.odb_network["net1"].google_oracle_database_odb_network.this` | `projects/P/locations/L/odbNetworks/NET` |
| Client subnet | `module.odb_network["net1"].google_oracle_database_odb_subnet.client` | `projects/P/locations/L/odbNetworks/NET/odbSubnets/SUB` |
| Backup subnet | `module.odb_network["net1"].google_oracle_database_odb_subnet.backup` | `projects/P/locations/L/odbNetworks/NET/odbSubnets/SUB` |
| Exadata infrastructure | `module.exadata_infra["infra1"].google_oracle_database_cloud_exadata_infrastructure.this` | `projects/P/locations/L/cloudExadataInfrastructures/INFRA` |
| VM cluster | `module.vm_cluster["vmc1"].google_oracle_database_cloud_vm_cluster.this` | `projects/P/locations/L/cloudVmClusters/VMC` |
| ODB network *(ADB-S only)* | `module.odb_network_adbs["adbnet1"].google_oracle_database_odb_network.this` | `projects/P/locations/L/odbNetworks/NET` |
| Client subnet *(ADB-S only)* | `module.odb_network_adbs["adbnet1"].google_oracle_database_odb_subnet.client` | `projects/P/locations/L/odbNetworks/NET/odbSubnets/SUB` |
| Autonomous Database | `module.autonomous_db["adb1"].google_oracle_database_autonomous_database.this` | `projects/P/locations/L/autonomousDatabases/ADB` |

> Adopting an Autonomous Database still needs its ADMIN password in `gcp_adb_admin_passwords`
> before the import — the argument is required, so the config is incomplete without it. The provider
> cannot read the existing password back, so give it the one the database actually has.
>
> The `ignore_changes` guard works in your favour here: the eight scaling fields listed in
> [§7.6](#eight-fields-are-guarded-and-will-not-plan) will not show as drift after the import even if
> your tfvars values do not match the live database.
>
> The ADB-S-only network module owns **two** resources, not three — there is no backup subnet to
> import.

> The network module owns **three** resources — the network and both subnets. Adopting a network
> means three import blocks, not one. Confirm the exact ID format against your provider version; the
> discovery commands below print the value to use.

#### Example: adopting an existing ODB network

```hcl
# imports.tf — delete this file once the imports have been applied

import {
  to = module.odb_network["net1"].google_oracle_database_odb_network.this
  id = "projects/my-project/locations/us-east4/odbNetworks/odbnet-prod"
}

import {
  to = module.odb_network["net1"].google_oracle_database_odb_subnet.client
  id = "projects/my-project/locations/us-east4/odbNetworks/odbnet-prod/odbSubnets/client-subnet"
}

import {
  to = module.odb_network["net1"].google_oracle_database_odb_subnet.backup
  id = "projects/my-project/locations/us-east4/odbNetworks/odbnet-prod/odbSubnets/backup-subnet"
}
```

with the matching entry describing what is really there:

```hcl
# terraform.tfvars
gcp_odb_networks = {
  net1 = {
    odb_network_id    = "odbnet-prod"           # ← must match the real resource ID
    location          = "us-east4"
    network           = "projects/my-project/global/networks/my-vpc"
    gcp_oracle_zone   = "us-east4-b-r1"
    client_subnet_id  = "client-subnet"         # ← must match
    client_cidr_range = "10.10.0.0/24"          # ← must match the real CIDRs
    backup_subnet_id  = "backup-subnet"
    backup_cidr_range = "10.10.1.0/24"
  }
}
```

#### Example: adopting an infrastructure and cluster

```hcl
import {
  to = module.exadata_infra["infra1"].google_oracle_database_cloud_exadata_infrastructure.this
  id = "projects/my-project/locations/us-east4/cloudExadataInfrastructures/exa-prod"
}

import {
  to = module.vm_cluster["vmc1"].google_oracle_database_cloud_vm_cluster.this
  id = "projects/my-project/locations/us-east4/cloudVmClusters/vmc-prod"
}
```

Clusters that already reference `network_key = "net1"` / `infra_key = "infra1"` need no change — the
keys now resolve to the imported resources. `db_servers_mode = "auto"` keeps working: the
`google_oracle_database_db_servers` data source queries the imported infra like any other.

#### Finding the IDs

```bash
gcloud oracle-database odb-networks list --location=us-east4
gcloud oracle-database cloud-exadata-infrastructures list --location=us-east4
gcloud oracle-database cloud-vm-clusters list --location=us-east4
```

The `name` field of each result is the full resource name to import verbatim. (Run
`gcloud oracle-database --help` to confirm subcommand names for your SDK version.)

#### Importing several at once

Terraform **1.7+** accepts `for_each` on import blocks, which is worth it when adopting a whole
estate:

```hcl
variable "import_infra_ids" {
  type    = map(string)
  default = {} # e.g. { infra1 = "projects/P/locations/L/cloudExadataInfrastructures/exa-prod" }
}

import {
  for_each = var.import_infra_ids
  to       = module.exadata_infra[each.key].google_oracle_database_cloud_exadata_infrastructure.this
  id       = each.value
}
```

On Terraform 1.5–1.6, write one static `import` block per resource instead.

---

## 9. Scaling: adding more resources

**Add a second VM cluster on the same infra/network** — just add a map entry:

```hcl
gcp_vm_clusters = {
  vmc1 = { infra_key = "infra1", network_key = "net1", cloud_vm_cluster_id = "vmc-prod", ... }
  vmc2 = {                                   # ← new
    infra_key               = "infra1"
    network_key             = "net1"
    cloud_vm_cluster_id     = "vmc-reporting"
    hostname_prefix         = "rpt"
    cpu_core_count          = 8
    memory_size_gb          = 120
    db_node_storage_size_gb = 120
    data_storage_size_tb    = 4
    ssh_public_keys         = ["ssh-rsa AAAA... your-key"]
  }
}
```

**Add a whole second stack** in another region: add a `net2` to `gcp_odb_networks`, an `infra2` to
`gcp_exadata_infras` (with its own `location`/`gcp_oracle_zone`), and a `vmc3` pointing at them.
No `.tf` changes — `terraform plan` will show only the additions.

### Adding an Autonomous Database

Add an entry to `gcp_autonomous_dbs` and a matching password to the environment. Several databases
can share one `network_key` with no extra thought — unlike VM clusters there is no per-instance
backup range to keep apart, because Oracle owns the storage beneath it:

```hcl
gcp_autonomous_dbs = {
  adb1 = {
    autonomous_database_id = "adb-prod"
    database               = "adbprod"
    network_key            = "net1"        # sharing the VM clusters' network
    compute_count          = 4
    data_storage_size_gb   = 500
  }
  adb2 = {                                 # ← new, same network, no collision to avoid
    autonomous_database_id = "adb-reporting"
    database               = "adbrpt"
    network_key            = "net1"
    db_workload            = "DW"
  }
}
```

```bash
export TF_VAR_gcp_adb_admin_passwords='{"adb1":"YourStr0ngPass","adb2":"An0therStr0ng"}'
```

**Resizing is not a tfvars edit here.** `compute_count` and `data_storage_size_gb` are inside the
module's `ignore_changes` guard, so changing them above produces no plan at all — see
[§7.6](#eight-fields-are-guarded-and-will-not-plan) for why, and for the comment-out-apply-restore
route when you mean it. This is the one place the GCP blueprint behaves differently from the Azure
one, where the same resize is a plain in-place update.

**Add an ADB-S-only network** when a network serves no VM clusters — one fewer subnet, one fewer
CIDR to plan for:

```hcl
gcp_odb_networks_adbs = {
  adbnet1 = {
    odb_network_id    = "odbnet-adb-prod"
    network           = "projects/my-gcp-project/global/networks/default"
    client_subnet_id  = "odb-client-adb-prod"
    client_cidr_range = "10.30.2.0/24"
  }
}
```

Then point a database at it with `network_key = "adbnet1"`. Keys are shared across both network
maps, so `adbnet1` must not also exist in `gcp_odb_networks` — a `check` block rejects that before
apply. And no VM cluster may reference it: `gcp_vm_clusters` resolves `network_key` against
`gcp_odb_networks` alone, so the plan fails with `Invalid index` naming the key.

---

## 10. Outputs

| Output | Shape | Notes |
|--------|-------|-------|
| `odb_networks` | map keyed by network key | `odb_network_name`, `client_subnet_name`, `backup_subnet_name` |
| `exadata_infras` | map keyed by infra key | `infra_name`, `ocid` |
| `vm_clusters` | map keyed by cluster key | `vm_cluster_name`, **`ocid`** |
| `db_servers` | map keyed by cluster key | list of discovered DB server OCIDs |
| `odb_networks_adbs` | map keyed by network key | `odb_network_name`, `client_subnet_name` — no backup subnet exists on these |
| `autonomous_databases` | map keyed by `gcp_autonomous_dbs` key | `autonomous_database_id`, `autonomous_database_name`, **`ocid`** |

```bash
terraform output vm_clusters
terraform output -json | jq '.vm_clusters.value.vmc1.ocid'
```

The cluster **`ocid`** is the handle you feed to the `oracle/oci` provider if you go on to create
DB Homes / CDBs / PDBs on the cluster.

The Autonomous **`ocid`** is not that kind of handoff. A Serverless database is already a database,
so there is no DB Home, CDB or PDB layer to build on it and nothing here feeds
[`oci-database`](../oci-database). The OCID is for referencing the database in OCI tooling — connect
to it with a wallet from the Google Cloud console or the OCI console.

---

## 11. Day-2 operations

- **Change CPU/memory/storage:** the VM cluster module marks `cpu_core_count`, `memory_size_gb`,
  `db_node_storage_size_gb`, `data_storage_size_tb`, `ssh_public_keys`, `db_server_ocids`,
  `ocpu_count`, and `node_count` under `lifecycle { ignore_changes }`. This prevents drift (e.g.
  elastic scaling performed in the console) from forcing a destroy/recreate. To resize *through
  Terraform*, remove the relevant field from `ignore_changes` in `modules/vm-cluster/main.tf` first.

  All three resources are `immutable` in the provider, so **any** drift proposes a replacement
  rather than an in-place update — which is why the guards exist at all. The guarded fields are the
  `default_from_api` ones, where the service supplies or normalises the value and comparing it
  against config produces a spurious rebuild. `ocpu_count` and `node_count` are harmless while left
  `null` (Terraform simply adopts what the API reports) and only become a risk once they are set
  explicitly in `terraform.tfvars`.

- **`gi_version` is deliberately *not* guarded.** The provider marks it `ignore_read: true`, so the
  resolved release the service reports is never read back over your config — the same is true of
  `hostname_prefix`, with the full name exposed separately as the read-only `hostname`. Adding them
  to `ignore_changes` would suppress genuine drift for no benefit. (Database@Azure behaves
  differently: there the API value *does* overwrite config, so the Azure blueprint has to guard it.)
- **Add SSH keys:** because `ssh_public_keys` is in `ignore_changes`, key changes via tfvars are not
  applied by default — manage keys in the console, or remove it from `ignore_changes`.
- **ODB network:** `gcp_oracle_zone` is under `ignore_changes` in `modules/odb-network/main.tf`. It
  is `default_from_api`, so the service picks a zone when none is given; guarding it stops a
  normalised value from proposing a replacement of the network and everything beneath it.
- **ODB network (ADB-S only):** `modules/odb-network-adbs` carries the same `gcp_oracle_zone` guard
  as `modules/odb-network`, for the same reason.
- **Autonomous databases are guarded too**, and more heavily: eight fields including `compute_count`
  and `data_storage_size_gb` sit under `ignore_changes`, because Autonomous scaling rewrites them in
  place. Resizing through Terraform means editing that `lifecycle` block — see
  [§7.6](#eight-fields-are-guarded-and-will-not-plan). Everything outside that list
  (`mtls_connection_required`, `customer_contacts`, `labels`, `operations_insights_state`,
  `maintenance_schedule_type`) updates normally.
- **State:** this blueprint uses local state by default. For team use, add a `backend "gcs"` block to
  `main.tf` and re-run `terraform init`. This matters more once you use `gcp_autonomous_dbs`: the
  ADMIN password is stored in state, so keep state remote and encrypted, never in git.

---

## 12. Destroying

`deletion_protection` defaults to **`true`** on networks, infras, clusters and Autonomous
databases. To tear down:

```hcl
# in terraform.tfvars, set deletion_protection = false on the entries you want to remove
```
```bash
terraform apply      # apply the deletion_protection = false change first
terraform destroy
```

Destroy order is handled automatically (clusters → infra → network, and Autonomous databases before
the network they attach to). **The data goes with an Autonomous database** — take a manual backup
first if you need one.

---

## 13. Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| `Error 403 ... oracledatabase.googleapis.com ... has not been used` | API not enabled — run the `gcloud services enable` command in §3. |
| `Error 403` / permission denied on apply | Missing `roles/oracledatabase.admin` or network roles on your identity. |
| `cannot delete ... deletion_protection is enabled` | Set `deletion_protection = false` for that entry and `apply` before `destroy`. |
| CIDR / subnet validation error | Client and backup CIDRs must be RFC1918, /27–/22, and non-overlapping. |
| Oracle zone not available | The `gcp_oracle_zone` isn't offered for your project/region — pick a valid zone. |
| Apply seems to hang for a long time | Expected — the ODB network (up to 4h) and VM cluster (4–8h) are the long poles; the infra finishes in ~20 min and then waits. See [§6.2](#62-provisioning-time). |
| `Invalid index` on `module.exadata_infra[...]` | A cluster's `infra_key`/`network_key` doesn't match an existing map key. |
| `Invalid index` on `module.odb_network[...]` for a network that exists | The key is in `gcp_odb_networks_adbs`, and a VM cluster cannot use an ADB-S-only network — it needs a backup subnet. Move the network to `gcp_odb_networks` or point the cluster elsewhere. |
| `Invalid index` on `var.gcp_adb_admin_passwords` | No ADMIN password for that `gcp_autonomous_dbs` key. Set `TF_VAR_gcp_adb_admin_passwords` — see [§7.6](#the-admin-password). |
| Autonomous DB rejects the ADMIN password | 12–30 chars, upper + lower + digit, no double quote, and it may not contain the word `admin`. |
| Editing `compute_count` produces no plan | Expected — it is one of eight fields under `ignore_changes` in `modules/autonomous-db`. See [§7.6](#eight-fields-are-guarded-and-will-not-plan). |
| Duplicate network key warning before apply | The same key is in both `gcp_odb_networks` and `gcp_odb_networks_adbs`. They share one keyspace — keep each network in one map. |
| `private_endpoint_ip` rejected | It must fall inside the network's `client_cidr_range`. Leave it empty and Oracle picks one. |

Validate before applying:

```bash
terraform fmt -recursive
terraform validate
```

---

## 14. FAQ

**Do I ever edit the `.tf` files?**
Only for things the maps don't expose (custom backends, removing an `ignore_changes` entry). Routine
work — more clusters, different sizes, new regions — is all in `terraform.tfvars`.

**Can I run this with OpenTofu?**
Yes. Replace `terraform` with `tofu`; OpenTofu resolves `hashicorp/google` from its own registry.

**Autonomous Serverless or a VM cluster?**
Serverless if you want a managed database with no infrastructure to size, patch or pay for while
idle — Oracle runs the fleet and you rent ECPUs. A VM cluster (Dedicated) if you need control of the
Exadata hardware, OS-level access, custom CDB/PDB layouts, or Data Guard between clusters. They are
independent maps in the same blueprint, so you can run either or both.

**Can I deploy only Autonomous databases?**
Yes. Leave `gcp_exadata_infras` and `gcp_vm_clusters` empty, fill in one network map and
`gcp_autonomous_dbs`. That skips both long poles — the ODB network is still the slowest step, but
there is no 4–8h VM cluster behind it.

**Which network map should an Autonomous Database use?**
Either. `gcp_odb_networks` if it shares a network with your VM clusters — the database uses the
client subnet and ignores the backup one. `gcp_odb_networks_adbs` if the network serves Autonomous
databases alone, which saves you a subnet and a CIDR. A VM cluster can only use the first.

**Is "Oracle AI Database" a different `db_version`?**
No — it is Oracle's branding for the 23ai-and-later line, not a separate version string. Set
`db_version = "23ai"`, which is this blueprint's default; the AI features (AI Vector Search, Select
AI, JSON Relational Duality) come with that release. The field is deliberately unvalidated, so when
your region offers a newer release you set it in `terraform.tfvars` without touching a `.tf` file —
though note `db_version` is also inside the `ignore_changes` guard, so an upgrade needs the
comment-out-apply-restore route in [§7.6](#eight-fields-are-guarded-and-will-not-plan).

**How do I create databases (CDB/PDB) on the cluster?**
Use the cluster `ocid` output with the `oracle/oci` provider. The main Terraflow Studio app can
generate that layer; this blueprint stops at the VM cluster.

**Is the state safe to commit?**
No — `terraform.tfstate` can contain sensitive values. Use a remote backend and keep state out of git.
