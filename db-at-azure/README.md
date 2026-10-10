# Oracle Database@Azure — Terraform Blueprint

A complete, standalone Terraform configuration for deploying **Oracle Database@Azure** — both
**Exadata Database Service** (Dedicated: infrastructure + VM cluster) and **Autonomous Database
Serverless**. You only edit [`terraform.tfvars`](terraform.tfvars) — the `.tf` files are reusable
as-is.

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
   - [`azure_vnets`](#72-azure_vnets)
   - [`azure_infras`](#73-azure_infras)
   - [`azure_clusters`](#74-azure_clusters)
   - [`azure_autonomous_dbs`](#75-azure_autonomous_dbs)
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

| Order | Resource | Terraform resource | Module | Optional |
|-------|----------|--------------------|--------|----------|
| 1 | Resource Anchor | `azurerm_oracle_resource_anchor` | `modules/resource-anchor` | yes |
| 2 | VNet + Oracle-delegated subnet | `azurerm_virtual_network`, `azurerm_subnet` | `modules/vnet` | |
| 3 | Network Anchor | `azapi_resource` (`Oracle.Database/networkAnchors`) | `modules/network-anchor` | yes |
| 4 | Exadata Infrastructure | `azurerm_oracle_exadata_infrastructure` | `modules/exadata-infra` | |
| 5 | VM Cluster | `azurerm_oracle_cloud_vm_cluster` | `modules/vm-cluster` | |
| — | Autonomous Database (Serverless) | `azurerm_oracle_autonomous_database` | `modules/autonomous-db` | yes |

The subnet is automatically **delegated to `Oracle.Database/networkAttachments`**, which Azure
requires before a VM cluster can attach to it.

### Anchors are opt-in

The two anchor maps default to empty, so a configuration that does not mention them
deploys exactly what it always did.

- **Resource Anchor** maps a resource group to an OCI compartment. It is the
  foundational Database@Azure resource — everything else needs one to exist in the
  resource group first. Nothing takes its ID as an argument, so the ordering is
  expressed with `depends_on` rather than by wiring.
- **Network Anchor** bridges the delegated subnet to OCI. Required for an Oracle
  **Base Database**; not needed for Exadata VM clusters on their own.

Already have anchors from a platform team? Put their IDs in
`existing_resource_anchor_ids` rather than describing them — see [9](#9-scaling-adding-more-resources).

### Autonomous Serverless sits beside the stack, not on it

`azure_autonomous_dbs` has no `infra_ref` and no step number in the table above, because
**Serverless is not Dedicated**: Oracle runs the Exadata fleet and the database is a slice of it.
There is no Exadata Infrastructure and no VM Cluster underneath, so it is not rows 4–5 with a sixth
bolted on — it is a parallel branch off the same VNet.

What it shares with the rest is the network. It attaches to the **same Oracle-delegated subnet**,
via `vnet_ref`, that the VM clusters use. Leave `vnet_ref` out and you get a public endpoint
governed by `allowed_ips` instead.

That independence cuts both ways: `azure_infras` and `azure_clusters` can be left empty and this
blueprint deploys **only** Autonomous databases — in minutes rather than the hours a VM cluster
takes ([§6.2](#62-provisioning-time)).

The ADMIN password is the one input that never goes in `terraform.tfvars`; it comes from
`TF_VAR_autonomous_db_admin_passwords` at apply time — see [§7.5](#75-azure_autonomous_dbs).

**Providers:** `hashicorp/azurerm >= 4.51.0`, plus `Azure/azapi >= 2.8.0` for Network
Anchors only — `azurerm` has no native resource for `Oracle.Database/networkAnchors`.
`required_providers` cannot be conditional, so azapi is always declared; with no
network anchors configured, nothing is created through it.
**Terraform:** `>= 1.5.0` (or OpenTofu `>= 1.6.0`).

---

## 2. Architecture

```
                          ┌─────────────────────────────────────────────┐
                          │   Azure subscription / resource group        │
                          │                                              │
  terraform.tfvars        │   ┌────────────────────────────────────┐    │
  ┌───────────────┐       │   │  VNet  (modules/vnet)               │    │
  │ azure_vnets    │──────┼──▶│   └─ subnet delegated to            │    │
  │                │      │   │      Oracle.Database/networkAttach… │    │
  ├───────────────┤       │   └────────────────────────────────────┘    │
  │ azure_infras   │──────┼──▶┌────────────────────────────────────┐     │
  │                │      │   │  Exadata Infrastructure             │    │
  ├───────────────┤       │   └──────────────┬─────────────────────┘    │
  │ azure_clusters │       │   ┌──────────────▼─────────────────────┐    │
  │                │──────┼──▶│  VM Cluster (modules/vm-cluster)    │    │
  ├───────────────┤       │   │  (attaches to delegated subnet)     │    │
  │ azure_         │      │   └─────────────────────────────────────┘    │
  │  autonomous_dbs│──────┼──▶┌─────────────────────────────────────┐    │
  └───────────────┘       │   │  Autonomous DB — Serverless         │    │
        map keys          │   │  (modules/autonomous-db)            │    │
   wire everything        │   │  no infra beneath: Oracle's fleet   │    │
                          │   └─────────────────────────────────────┘    │
                          └─────────────────────────────────────────────┘
```

The maps in `terraform.tfvars` are joined by **keys**, not by IDs:

```
azure_clusters["vmc1"].vnet_ref       = "vnet1"   ─▶ azure_vnets["vnet1"]
azure_clusters["vmc1"].infra_ref      = "infra1"  ─▶ azure_infras["infra1"]
azure_autonomous_dbs["adb1"].vnet_ref = "vnet1"   ─▶ azure_vnets["vnet1"]   (optional)
```

The Autonomous branch stops at the VNet. It has no `infra_ref` because nothing of yours sits
underneath it.

---

## 3. Prerequisites

Before `terraform apply`:

1. **Oracle Database@Azure enabled** for your subscription. Set it up through the Azure Marketplace
   (“Oracle Database@Azure”) and complete the Oracle/Azure account linking. This is a one-time,
   subscription-level step done outside Terraform.
2. **An existing resource group.** This blueprint does **not** create it — set `resource_group_name`
   to one that already exists:
   ```bash
   az group create --name rg-oracle-prod --location eastus    # if you need to create one
   ```
3. **The `Oracle.Database` resource provider registered** in the subscription:
   ```bash
   az provider register --namespace Oracle.Database
   ```
4. **A region where Oracle Database@Azure is offered**, and the availability **zone** number for it
   (e.g. `"2"`). Autonomous Database Serverless takes no zone — Oracle places it — but the
   `db_version` and workload you want must be offered in that region.
5. **RBAC permissions** to create networking + Oracle.Database resources in the resource group.
6. **Capacity / quota** for the chosen shape in that region/zone. Serverless is quota'd in **ECPUs**
   rather than by shape.
7. **Terraform `>= 1.5.0`** (the configuration uses optional object attributes).

---

## 4. Authentication

Sign in with the Azure CLI and select the subscription:

```bash
az login
az account set --subscription "00000000-0000-0000-0000-000000000000"
```

Set the same `subscription_id` in `terraform.tfvars` (the provider has
`subscription_id = var.subscription_id`). For automation, a service principal works too:

```bash
export ARM_CLIENT_ID=...  ARM_CLIENT_SECRET=...  ARM_TENANT_ID=...  ARM_SUBSCRIPTION_ID=...
```

---

## 5. Repository layout

```
db-at-azure/
├── main.tf              # provider + module wiring (do not need to edit)
├── variables.tf         # variable definitions (do not need to edit)
├── outputs.tf           # outputs (do not need to edit)
├── terraform.tfvars     # ◀── YOU EDIT THIS
└── modules/
    ├── resource-anchor/ # Resource Anchor  (optional, foundational)
    ├── vnet/            # VNet + Oracle-delegated subnet
    ├── network-anchor/  # Network Anchor   (optional, needs a subnet + Resource Anchor)
    ├── exadata-infra/   # Exadata infrastructure
    ├── vm-cluster/      # VM cluster
    └── autonomous-db/   # Autonomous Database Serverless (optional, no infra beneath)
```

---

## 6. Quick start

```bash
cd db-at-azure

# 1. authenticate
az login

# 2. edit terraform.tfvars — set subscription_id, resource_group_name (must exist),
#    location, VNet/subnet CIDRs, zone, and your real SSH public key

# 3. only if you filled in azure_autonomous_dbs — ADMIN passwords never go in tfvars.
#    One entry per azure_autonomous_dbs key:
export TF_VAR_autonomous_db_admin_passwords='{"adb1":"YourStr0ngPass"}'

# 4. run
terraform init
terraform plan           # review what will be created
terraform apply
```

### 6.1 Order of operations

One `terraform apply` builds everything. Terraform derives the order from the module graph — you do
not stage it:

```
resource_anchor ──────────────▶ exadata_infra ─┐
vnet ──▶ network_anchor ───────────────────────┴──▶ vm_cluster
    └──────────────────────────────────────────────▶ autonomous_db
```

The Exadata infrastructure takes no argument from the Resource Anchor, but the anchor must exist in
the resource group first — an explicit `depends_on` enforces that. With both anchor maps empty the
anchor steps drop out and the graph is simply `vnet → exadata_infra → vm_cluster`.

Autonomous databases hang off the VNet alone (plus the same `depends_on` for the anchor). They do
not wait for the infrastructure or the cluster and are built in parallel with them, so adding one to
an existing stack costs nothing on the critical path.

### 6.2 Provisioning time

This apply is measured in **hours, not minutes**. Plan a window and let it run to completion.

| Resource | Typical elapsed | Module timeout ceiling |
|----------|-----------------|------------------------|
| VNet + delegated subnet | ~2–5 min | provider default (module sets none) |
| Resource Anchor *(optional)* | ~10–30 min | create 1h · delete 1h |
| Network Anchor *(optional)* | ~10–30 min | provider default (module sets none) |
| Exadata infrastructure | ~15–20 min | create 6h · delete 3h |
| **VM cluster** | **~4–8 h** | create 12h · update 2h · delete 8h |
| Autonomous Database *(optional)* | ~5–15 min | provider default (module sets none) |
| **Full apply (critical path)** | **~5–9 h** | — |

**The Exadata infrastructure is the fastest thing here, not the slowest.** The hardware provisions in
15–20 minutes; the **VM cluster** (4–8 h) dominates the build and is the only figure worth budgeting
on. Because the anchor/infra and VNet/anchor branches run in parallel and both finish inside ~30
minutes, the critical path is essentially the cluster plus a short head start.

**An Autonomous-only apply is a different exercise entirely.** With `azure_infras` and
`azure_clusters` empty, the critical path is the VNet plus the database — minutes, not hours.
Serverless provisions against Oracle's existing fleet; there is no hardware to stand up.

Azure has no ODB network resource — the networking here is a plain Azure VNet and delegated subnet,
which is quick. On [`db-at-aws`](../db-at-aws) and [`db-at-gcp`](../db-at-gcp) the ODB network is a
second long pole (up to ~4 h), pushing those builds to 8–12 h; this blueprint has no equivalent step.

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

Destroying is no faster — 8h on the cluster, 3h on the infra. And because every VM cluster argument
is ForceNew, a change Terraform cannot apply in place proposes **replacement**, paying the
multi-hour cluster build again — see [§11](#11-day-2-operations).

---

## 7. Variable reference

### 7.1 Top-level variables

| Variable | Type | Required | Description |
|----------|------|----------|-------------|
| `subscription_id` | string | ✅ | Azure subscription ID. |
| `resource_group_name` | string | ✅ | Existing resource group (not created by this config). |
| `location` | string | ✅ | Azure region, e.g. `eastus`. |
| `tags` | map(string) | — | Tags applied to all resources. Default `{}`. |
| `azure_autonomous_dbs` | map(object) | — | Autonomous Databases (Serverless). Default `{}` — see [§7.5](#75-azure_autonomous_dbs). |
| `autonomous_db_admin_passwords` | map(string), sensitive | — | ADMIN password per `azure_autonomous_dbs` key. **Never put this in `terraform.tfvars`** — export `TF_VAR_autonomous_db_admin_passwords`. Default `{}`. |

The map variables that drive the rest — `azure_resource_anchors`,
`existing_resource_anchor_ids`, `azure_network_anchors`, `azure_vnets`, `azure_infras`,
`azure_clusters` — all default to `{}` and are documented in the sections below.

### 7.2 `azure_vnets`

Map of VNets, each with one Oracle-delegated subnet. The map **key** is referenced by
`azure_clusters[*].vnet_ref`, `azure_network_anchors[*].vnet_ref` and
`azure_autonomous_dbs[*].vnet_ref`. One delegated subnet can carry VM clusters and Autonomous
databases at the same time.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `vnet_name` | string | — (required) | Name of the virtual network. |
| `address_space` | string | — (required) | VNet CIDR, e.g. `10.20.0.0/16`. |
| `subnet_name` | string | — (required) | Name of the delegated subnet. |
| `subnet_address_prefix` | string | — (required) | Subnet CIDR, e.g. `10.20.1.0/24`. |

> The subnet is created with a `delegation` block for `Oracle.Database/networkAttachments` — you do
> not configure this yourself.

### 7.3 `azure_infras`

Map of Exadata infrastructures. The map **key** is referenced by `azure_clusters[*].infra_ref`.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | string | — (required) | Azure resource name. |
| `display_name` | string | — (required) | Friendly display name. |
| `zone` | string | — (required) | Availability zone **number** as a string, e.g. `"2"`. |
| `shape` | string | `Exadata.X11M` | Exadata shape. |
| `compute_count` | number | `2` | Compute nodes. |
| `storage_count` | number | `3` | Storage servers. |

> The module also exposes maintenance-window inputs (`mw_preference`, `mw_patching_mode`,
> `mw_lead_time_in_weeks`, `mw_days_of_week`, etc.) with sensible defaults. To use a custom window,
> pass them through `main.tf` or extend the `azure_infras` object type.

### 7.4 `azure_clusters`

Map of VM clusters. `infra_ref` and `vnet_ref` must match keys in `azure_infras` / `azure_vnets`.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | string | — (required) | Azure resource name. |
| `display_name` | string | — (required) | Friendly display name. |
| `hostname` | string | — (required) | Hostname for cluster nodes. |
| `infra_ref` | string | — (required) | Key into `azure_infras`. |
| `vnet_ref` | string | — (required) | Key into `azure_vnets`. |
| `cpu_core_count` | number | `4` | Enabled CPU cores. |
| `data_storage_size_in_tbs` | number | `2` | Data storage (TB). |
| `memory_size_in_gbs` | number | `60` | Memory (GB). |
| `db_node_storage_size_in_gbs` | number | `120` | Local node storage (GB). |
| `gi_version` | string | `23.0.0.0` | Grid Infrastructure **major-version selector**. Oracle resolves it to the running release (`19.0.0.0` → `19.32.0.0.0`) and stores that in state, so config and state never match — see [9](#9-scaling-adding-more-resources). Covered by the module's `ignore_changes` guard. |
| `license_model` | string | `LicenseIncluded` | or `BringYourOwnLicense` (Azure-style casing). |
| `ssh_public_keys` | list(string) | `[]` | SSH keys for node access (set this!). |
| `local_backup_enabled` | bool | `false` | Enable local backups. |
| `sparse_diskgroup_enabled` | bool | `false` | Enable sparse disk group. |
| `cluster_name` | string | `""` | Optional cluster name. |
| `time_zone` | string | `UTC` | e.g. `America/New_York`. |
| `scan_listener_port_tcp` | number | `1521` | SCAN listener port. |
| `backup_subnet_cidr` | string | `192.168.252.0/22` | Backup range Oracle carves inside the VNet, e.g. `10.0.11.0/24`. Must differ per cluster when several share a `vnet_ref` — see [9](#9-scaling-adding-more-resources). **Never set it to `""`**: the attribute is `ForceNew` and not `Computed`, so an empty config makes every later plan propose replacing the cluster. |

> The underlying module supports further fields that this root does not expose yet (`domain`,
> `data_storage_percentage`, `scan_listener_port_tcp_ssl`, `system_version`, `zone_id`, `db_servers`,
> `file_system_configuration`, and the `dco_*` toggles). Add them to the `azure_clusters` object type
> in `variables.tf` and wire them in `main.tf` if you need them.

### 7.5 `azure_autonomous_dbs`

Map of **Autonomous Database Serverless** instances. There is no `infra_ref` — see
[§1](#autonomous-serverless-sits-beside-the-stack-not-on-it). `vnet_ref` is optional and, when set,
must match a key in `azure_vnets`.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | string | — (required) | Azure resource name. |
| `display_name` | string | — (required) | Name shown in the OCI console. |
| `vnet_ref` | string | `null` | Key into `azure_vnets`. Set it for a **private** endpoint on the Oracle-delegated subnet. Leave it out for a **public** endpoint and use `allowed_ips`. |
| `db_workload` | string | `OLTP` | `OLTP` (transaction processing), `DW` (data warehouse), `AJD` (JSON) or `APEX`. |
| `db_version` | string | `23ai` | `19c` or `23ai`. Deliberately unvalidated — a newer release is a tfvars edit, not a code change. |
| `license_model` | string | `LicenseIncluded` | or `BringYourOwnLicense` (Azure-style casing). |
| `compute_model` | string | `ECPU` | `OCPU` is legacy; use ECPU for anything new. |
| `compute_count` | number | `2` | ECPUs. Minimum 2 on the ECPU model; fractional values allowed. |
| `data_storage_size_in_tbs` | number | `1` | Storage in TB, minimum 1. |
| `auto_scaling_enabled` | bool | `false` | Let compute scale up to **3×** the base count on demand. |
| `auto_scaling_for_storage_enabled` | bool | `false` | Let storage grow past the reserved size. |
| `backup_retention_period_in_days` | number | `60` | Automatic backup retention, 1–60. |
| `character_set` | string | `AL32UTF8` | Database character set. |
| `national_character_set` | string | `AL16UTF16` | NCHAR character set. |
| `mtls_connection_required` | bool | `true` | Require mutual TLS. `false` allows TLS-only clients. |
| `allowed_ips` | list(string) | `[]` | Public access ACL (IPs or CIDRs). **Only meaningful without `vnet_ref`** — on a delegated subnet it is ignored. |
| `customer_contacts` | list(string) | `[]` | Email addresses Oracle notifies about this database. |

#### The ADMIN password

The provider requires an ADMIN password, and it is the one input this blueprint refuses to read from
`terraform.tfvars`. It comes from a separate **sensitive map**, `autonomous_db_admin_passwords`,
keyed by the same key as the database:

```bash
export TF_VAR_autonomous_db_admin_passwords='{"adb1":"YourStr0ngPass","adb2":"An0therStr0ng"}'
```

```powershell
$env:TF_VAR_autonomous_db_admin_passwords = '{"adb1":"YourStr0ngPass"}'
```

Oracle's rules: **12–30 characters**, at least one uppercase, one lowercase and one digit, no double
quote, and it may not contain the word `admin`.

Miss a key and the plan stops with `Invalid index` on `var.autonomous_db_admin_passwords`, naming
the database it could not find a password for. A `check` block reports the same thing in plainer
words first. The passwords themselves are never printed: the variable is `sensitive`, and only the
map's **key names** are unwrapped to build that message.

> The password is written to state. Use a remote backend with encryption at rest — see
> [§11](#11-day-2-operations).

---

## 8. How resources are wired

You never paste a subnet ID, VNet ID, or infra ID. The root `main.tf` resolves them:

```hcl
# cluster → infra ID (from the infra module output)
cloud_exadata_infrastructure_id = module.exadata_infra[each.value.infra_ref].infra_id

# cluster → delegated subnet ID + VNet ID (from the vnet module outputs)
subnet_id          = module.vnet[each.value.vnet_ref].subnet_id
virtual_network_id = module.vnet[each.value.vnet_ref].vnet_id

# autonomous DB → the same subnet, but vnet_ref is optional. A null one means a
# public endpoint, so empty strings go down and the module turns them into null:
# "" is not a valid resource ID, and these attributes are Optional in the schema.
subnet_id          = each.value.vnet_ref == null ? "" : module.vnet[each.value.vnet_ref].subnet_id
virtual_network_id = each.value.vnet_ref == null ? "" : module.vnet[each.value.vnet_ref].vnet_id
```

That's why the only thing you set in tfvars is the **key** (`infra_ref = "infra1"`).

### 8.1 Importing existing resources

Use this when a component was provisioned outside Terraform (portal, `az` CLI, another team) and you
want Terraform to **manage** it from now on — as opposed to `existing_resource_anchor_ids`, which
only references an anchor.

The rule: **write the config to match what already exists, then import, then confirm a clean plan.**
Terraform does not generate the config from the resource; you describe reality and the import
attaches state to it.

#### The workflow

```bash
# 1. Describe the existing resource in terraform.tfvars, matching its real settings exactly
# 2. Add an import block (below) naming the module address and the ARM resource ID
terraform plan          # ◀── must report "0 to add, 0 to change, 0 to destroy"
terraform apply         # records the import in state
# 3. Delete the import block — it has done its job
```

**A clean plan is the acceptance test.** If the plan proposes *changes*, your tfvars do not match
reality — fix the tfvars, not the resource. If it proposes *replacement*, something ForceNew
disagrees (usually `zone`, `shape`, or the subnet); fix that before applying or you will destroy the
resource you just imported.

For the anchors, the `prevent_destroy` guards in [§12](#12-destroying) work in your favour: a
replacement plan **errors out** instead of proceeding, so a mismatched import fails loudly.

#### Module addresses and import IDs

Every module is `for_each`'d, so the address carries the **map key** in quotes — the same key you use
in `terraform.tfvars`. Azure resources import by their **full ARM resource ID**:

| Resource | Import block `to` address | ID to import |
|----------|---------------------------|--------------|
| Resource Anchor | `module.resource_anchor["anchor1"].azurerm_oracle_resource_anchor.this` | `/subscriptions/…/providers/Oracle.Database/resourceAnchors/NAME` |
| VNet | `module.vnet["vnet1"].azurerm_virtual_network.this` | `/subscriptions/…/providers/Microsoft.Network/virtualNetworks/NAME` |
| Delegated subnet | `module.vnet["vnet1"].azurerm_subnet.oracle_delegated` | `/subscriptions/…/virtualNetworks/VNET/subnets/NAME` |
| Network Anchor | `module.network_anchor["na1"].azapi_resource.this` | `/subscriptions/…/providers/Oracle.Database/networkAnchors/NAME` |
| Exadata infrastructure | `module.exadata_infra["infra1"].azurerm_oracle_exadata_infrastructure.this` | `/subscriptions/…/providers/Oracle.Database/cloudExadataInfrastructures/NAME` |
| VM cluster | `module.vm_cluster["vmc1"].azurerm_oracle_cloud_vm_cluster.this` | `/subscriptions/…/providers/Oracle.Database/cloudVmClusters/NAME` |
| Autonomous Database | `module.autonomous_db["adb1"].azurerm_oracle_autonomous_database.this` | `/subscriptions/…/providers/Oracle.Database/autonomousDatabases/NAME` |

> Adopting an Autonomous Database still needs its ADMIN password in
> `autonomous_db_admin_passwords` before the import — the argument is required, so the config is
> incomplete without it. The provider cannot read the existing password back, so give it the one the
> database actually has, or expect the first plan after the import to propose changing it.

> The VNet module owns **two** resources — the VNet and the delegated subnet. Adopting a VNet means
> two import blocks. Confirm the exact ID format against your provider version; `az resource show`
> below prints the value to use verbatim.

#### Example: adopting an existing VNet and infrastructure

```hcl
# imports.tf — delete this file once the imports have been applied

import {
  to = module.vnet["vnet1"].azurerm_virtual_network.this
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-oracle/providers/Microsoft.Network/virtualNetworks/vnet-oracle"
}

import {
  to = module.vnet["vnet1"].azurerm_subnet.oracle_delegated
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-oracle/providers/Microsoft.Network/virtualNetworks/vnet-oracle/subnets/snet-oracle-delegated"
}

import {
  to = module.exadata_infra["infra1"].azurerm_oracle_exadata_infrastructure.this
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-oracle/providers/Oracle.Database/cloudExadataInfrastructures/exa-prod"
}
```

with the matching entries describing what is really there:

```hcl
# terraform.tfvars
azure_vnets = {
  vnet1 = {
    vnet_name             = "vnet-oracle"       # ← must match
    address_space         = "10.10.0.0/16"      # ← must match
    subnet_name           = "snet-oracle-delegated"
    subnet_address_prefix = "10.10.1.0/24"
  }
}

azure_infras = {
  infra1 = {
    name          = "exa-prod"                  # ← must match
    display_name  = "exa-prod"
    shape         = "Exadata.X11M"              # ← must match the real shape
    compute_count = 2
    storage_count = 3
    zone          = "2"                         # ← must match
  }
}
```

Clusters that already reference `vnet_ref = "vnet1"` / `infra_ref = "infra1"` need no change — the
keys now resolve to the imported resources.

#### Importing the Network Anchor (`azapi`)

The Network Anchor goes through the **`azapi`** provider rather than `azurerm`, so its import is the
one that behaves differently — the ID carries the API version as a query string, and it must match
the `type` pinned in the module (`Oracle.Database/networkAnchors@2025-09-01`):

```hcl
import {
  to = module.network_anchor["na1"].azapi_resource.this
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-oracle/providers/Oracle.Database/networkAnchors/na-prod?api-version=2025-09-01"
}
```

An `azapi` import with a mismatched or missing `api-version` fails or produces a permanent diff in
`body`. If the plan will not settle, check that version first.

#### Finding the IDs

```bash
# Full ARM ID of any resource, ready to paste
az resource show -g rg-oracle -n exa-prod \
  --resource-type Oracle.Database/cloudExadataInfrastructures --query id -o tsv

# Everything Oracle in a resource group
az resource list -g rg-oracle --query "[?starts_with(type,'Oracle.Database')].{name:name,type:type,id:id}" -o table

# VNets and subnets
az network vnet list -g rg-oracle --query "[].{name:name,id:id}" -o table

# Autonomous Databases in the group
az resource list -g rg-oracle --resource-type Oracle.Database/autonomousDatabases   --query "[].{name:name,id:id}" -o table
```

#### Importing several at once

Terraform **1.7+** accepts `for_each` on import blocks, which is worth it when adopting a whole
estate:

```hcl
variable "import_infra_ids" {
  type    = map(string)
  default = {} # e.g. { infra1 = "/subscriptions/…/cloudExadataInfrastructures/exa-prod" }
}

import {
  for_each = var.import_infra_ids
  to       = module.exadata_infra[each.key].azurerm_oracle_exadata_infrastructure.this
  id       = each.value
}
```

On Terraform 1.5–1.6, write one static `import` block per resource instead.

#### Import or reference?

For **Resource Anchors** you have both options, and they are not the same:

| | `existing_resource_anchor_ids` | `import` |
|---|---|---|
| Terraform manages it | No — read-only reference | **Yes** |
| Appears in `terraform destroy` | No | **Yes** (blocked by `prevent_destroy`) |
| Config must match reality | No | **Yes**, exactly |
| Use when | A platform team owns it | You are taking ownership |

Mixing is fine: import the infrastructure you own and reference the anchor another team runs.

---

## 9. Scaling: adding more resources

**Add a second VM cluster on the same infra/VNet** — just add a map entry. Pointing at the same
`vnet_ref` reuses the existing delegated subnet; no second subnet is created.

The one field you must not reuse is `backup_subnet_cidr`. The delegated subnet is shared by design,
but Oracle carves the backup range inside the VNet **per cluster** — so once more than one cluster
shares a `vnet_ref`, give each its own non-overlapping range:

```hcl
azure_clusters = {
  vmc1 = {
    name = "vmc-prod", display_name = "VM Cluster Prod", hostname = "exadb"
    infra_ref = "infra1", vnet_ref = "vnet1"
    backup_subnet_cidr = "10.0.10.0/24"      # ← add one to the existing cluster too
    ...
  }
  vmc2 = {                                   # ← new
    name               = "vmc-reporting"
    display_name       = "VM Cluster Reporting"
    hostname           = "rpt"
    infra_ref          = "infra1"
    vnet_ref           = "vnet1"             # same delegated subnet as vmc1
    backup_subnet_cidr = "10.0.11.0/24"      # must not overlap vmc1's
    cpu_core_count     = 8
    ssh_public_keys    = ["ssh-rsa AAAA... your-key"]
  }
}
```

Pick ranges inside the VNet `address_space` that do not overlap each other or the delegated
`subnet_address_prefix`. Terraform does not check this for you — a collision surfaces as an Azure
error during apply. Both clusters default to the same `192.168.252.0/22`, so the second one must be
given its own range.

**Never set `backup_subnet_cidr` to `""`.** The attribute is `ForceNew` and not `Computed`, and the
provider reads the API's value back into state. An empty config therefore compares `null` against
the range the service assigned, and every later `terraform plan` proposes **destroying and
recreating the cluster** — a multi-hour rebuild. Always state the range explicitly; the default
`192.168.252.0/22` is the range the service would have picked anyway.

### Adding an Autonomous Database

Add an entry to `azure_autonomous_dbs` and a matching password to the environment. Several databases
can share one `vnet_ref` with no extra thought — unlike VM clusters, Serverless has no per-instance
backup range to keep apart, because Oracle owns the storage beneath it:

```hcl
azure_autonomous_dbs = {
  adb1 = {
    name         = "adb-prod-eastus"
    display_name = "Autonomous Prod"
    vnet_ref     = "vnet1"           # private endpoint on the delegated subnet
    compute_count            = 4
    data_storage_size_in_tbs = 2
    auto_scaling_enabled     = true  # burst to 12 ECPUs
  }
  adb2 = {                           # ← new, same subnet, no collision to avoid
    name         = "adb-reporting-eastus"
    display_name = "Autonomous Reporting"
    vnet_ref     = "vnet1"
    db_workload  = "DW"
  }
}
```

```bash
export TF_VAR_autonomous_db_admin_passwords='{"adb1":"YourStr0ngPass","adb2":"An0therStr0ng"}'
```

**Resizing is online.** `compute_count` and `data_storage_size_in_tbs` scale in place — no
`ForceNew`, none of the multi-hour replacement risk that dominates day-2 work on a VM cluster
([§11](#11-day-2-operations)). Changing `name`, `character_set` or `national_character_set` does
replace the database; the rest of the map is a normal update.

Turn on `auto_scaling_enabled` and Oracle scales compute up to **3×** `compute_count` on demand and
bills the difference. The base count is what you reserve, not what you cap.

### Why the module has an `ignore_changes` guard

On `azurerm_oracle_cloud_vm_cluster` almost every argument is `ForceNew`, and the provider's
`Update()` handles only `tags` and `file_system_configuration`. **Anything else that changes outside
Terraform proposes destroying the cluster rather than correcting it** — a multi-hour rebuild.

Three optional arguments are `ForceNew` *without* being `Computed`, which makes them the ones that
diff against an empty config. They are guarded by default:

| Guarded | Why |
|---|---|
| `backup_subnet_cidr` | Not `Computed`, so a blank config diffs against the range the service assigns. |
| `gi_version` | A **major-version selector** — Oracle resolves `19.0.0.0` to the running release (`19.32.0.0.0`) and stores that. It moves again with every quarterly GI patch, so pinning the resolved release only delays the diff. |
| `scan_listener_port_tcp_ssl` | Passed as `null` unless you set a port, so it diffs against any port the service assigns. |

The other optional arguments — `cluster_name`, `domain`, `time_zone`, `system_version`, `zone_id`,
`data_storage_percentage`, `local_backup_enabled`, `sparse_diskgroup_enabled` — **are** `Computed`.
Terraform adopts the state value when config omits them, so they need no guard while left blank and
guarding them would cost you real drift detection.

### Attributes changed outside Terraform

If your operations team patches or scales the cluster through the OCI console or Azure portal,
Terraform sees that as drift on a `ForceNew` attribute and proposes a rebuild. The module ships
these commented out in `modules/vm-cluster/main.tf` — uncomment the ones that apply to you:

```hcl
# system_version,              # Exadata image patching
# cpu_core_count,              # online OCPU scaling from the console
# ssh_public_keys,             # key rotation on the nodes
# data_storage_size_in_tbs,    # storage scaling
# memory_size_in_gbs,          # memory scaling
# db_node_storage_size_in_gbs, # local storage scaling
```

`cpu_core_count` deserves particular attention: Oracle supports **online** OCPU scaling, so an
operator resizing the cluster from the console leaves Terraform proposing to destroy it.

Each entry you add is drift Terraform will no longer report, so add them deliberately rather than
pre-emptively.

To change a guarded value deliberately, edit it and force the replacement yourself:

```bash
terraform apply -replace='module.vm_cluster["vmc1"].azurerm_oracle_cloud_vm_cluster.this'
```

One consequence worth knowing: with that guard in place Terraform will no longer report drift on
this field, so the cluster silently keeps whatever range Azure actually assigned. Confirm it once
after the first apply:

```bash
terraform state show 'module.vm_cluster["vmc1"].azurerm_oracle_cloud_vm_cluster.this' | grep backup_subnet_cidr
```

### Adding anchors, or reusing existing ones

Both anchor maps are empty by default. To have this blueprint create them:

```hcl
azure_resource_anchors = {
  anchor1 = { name = "anchor-oracle-prod" }
}

azure_network_anchors = {
  netanchor1 = {
    name       = "netanchor-prod"
    anchor_ref = "anchor1"     # key in azure_resource_anchors
    vnet_ref   = "vnet1"       # key in azure_vnets - supplies the delegated subnet
    zones      = ["2"]
  }
}
```

If a platform team already created the Resource Anchor, give its ID instead and keep
the same key:

```hcl
existing_resource_anchor_ids = {
  anchor1 = "/subscriptions/.../providers/Oracle.Database/resourceAnchors/anchor-oracle-prod"
}

azure_resource_anchors = {}          # anchor1 is not created - it already exists
azure_network_anchors = {
  netanchor1 = { name = "netanchor-prod", anchor_ref = "anchor1", vnet_ref = "vnet1" }
}
```

Managed and existing anchors share one keyspace, so `anchor_ref` resolves the same way
whichever side an anchor lives on, and the two can be mixed. A key present in **both**
maps is rejected before apply by a `check` block — that combination would create the
anchor *and* wire everything to the pre-existing one, orphaning what was just built.

#### Anchor gotchas

- **The Resource Anchor takes no `location`.** It inherits its region from the resource
  group, and `location` comes back as an output rather than an input.
- **The Network Anchor's API version is pinned** to `2025-09-01` in
  `modules/network-anchor/main.tf`. Bump it there if you need a newer one.
- **Renaming a map key destroys and recreates that anchor** — the key is its Terraform
  identity. Given both carry `prevent_destroy`, a rename fails the plan rather than
  quietly rebuilding, which is the intended outcome.
- A Network Anchor is required for an Oracle **Base Database**, not for Exadata VM
  clusters on their own.

Both anchor modules carry `prevent_destroy`. Destroying a Resource Anchor unlinks the
OCI compartment everything else in the resource group hangs off; destroying a Network
Anchor cuts the path between the delegated subnet and OCI. To remove one deliberately,
delete the `lifecycle` block from that module, apply, then destroy.

**Add a whole second stack** in another region: add a `vnet2` to `azure_vnets`, an `infra2` to
`azure_infras` (with its own `zone`), and a `vmc3` pointing at them. No `.tf` changes — `terraform
plan` shows only the additions. (All resources land in the single `resource_group_name`/`location`;
for multiple regions, run separate root configurations or extend the modules to take per-entry
location.)

---

## 10. Outputs

| Output | Shape | Notes |
|--------|-------|-------|
| `vnets` | map keyed by VNet key | `vnet_id`, `subnet_id` |
| `exadata_infras` | map keyed by infra key | `infra_id`, `infra_name` |
| `vm_clusters` | map keyed by cluster key | `cluster_id`, **`ocid`** |
| `autonomous_databases` | map keyed by `azure_autonomous_dbs` key | `id`, `name` |

```bash
terraform output vm_clusters
terraform output -json | jq '.vm_clusters.value.vmc1.ocid'
```

The cluster **`ocid`** is the handle you feed to the `oracle/oci` provider if you go on to create
DB Homes / CDBs / PDBs on the cluster.

`autonomous_databases` has no equivalent handoff, and that is the point: a Serverless database is
already a database. There is no DB Home, CDB or PDB layer to build on it, so nothing here feeds
[`oci-database`](../oci-database). Connect to it with a wallet from the Azure portal or the OCI
console.

---

## 11. Day-2 operations

- **Resource group is assumed to exist** — this config never creates or deletes it, so `destroy`
  leaves the RG intact.
- **Subnet delegation** is fixed to `Oracle.Database/networkAttachments`; don't repurpose the
  delegated subnet for other workloads.
- **Long-running creates** are covered by module `timeouts`. If you raise shapes/counts substantially,
  you may want to increase them further.
- **Autonomous resizing is online** — `compute_count` and `data_storage_size_in_tbs` change in
  place, unlike almost every VM-cluster field. See [§9](#adding-an-autonomous-database) for what
  does force replacement.
- **State:** local by default. For team use, add a `backend "azurerm"` block to `main.tf` and re-init.
  This matters more once you use `azure_autonomous_dbs`: the ADMIN password is stored in state, so
  keep state remote and encrypted, never in git.

---

## 12. Destroying

```bash
terraform destroy
```

Destroy order is handled automatically (cluster → infra → VNet/subnet, and Autonomous databases
before the VNet they attach to). The pre-existing resource group is not touched.

Autonomous databases carry no `prevent_destroy` guard and are torn down in minutes. **The data goes
with them** — take a manual backup first if you need one.

**Anchors are delete-protected.** If you configured `azure_resource_anchors` or
`azure_network_anchors`, those modules carry `lifecycle { prevent_destroy = true }` — the resource
anchor because destroying it unlinks the OCI compartment every other Database@Azure resource in the
group hangs off, the network anchor because it is the path between the delegated subnet and OCI.
`terraform destroy` fails with an error naming the resource rather than cutting that link.

To tear one down deliberately, delete the `lifecycle` block from that module's `main.tf`, `apply`,
then destroy:

```bash
# e.g. to allow the resource anchor to be destroyed
#   edit modules/resource-anchor/main.tf, remove the lifecycle block
terraform apply
terraform destroy
```

`prevent_destroy` only accepts a literal, so unlike the GCP blueprint's `deletion_protection` input
it cannot be toggled from `terraform.tfvars` — editing the module is the only route. With both
anchor maps left empty, nothing is protected and the plain `terraform destroy` above just works.

---

## 13. Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| `MissingSubscriptionRegistration` for `Oracle.Database` | Run `az provider register --namespace Oracle.Database`. |
| `ResourceGroupNotFound` | `resource_group_name` doesn't exist — create it or fix the name. |
| Subnet delegation / attachment errors | The subnet must be delegated to `Oracle.Database/networkAttachments` (the module does this) and not used by other resources. |
| Invalid `zone` | Use the zone **number** as a string (`"2"`), and one offered for Oracle in your region. |
| `license_model` rejected | Use Azure casing: `LicenseIncluded` or `BringYourOwnLicense`. |
| `Invalid index` on `module.exadata_infra[...]` | A cluster's `infra_ref`/`vnet_ref` doesn't match an existing map key. |
| `Invalid index` on `var.autonomous_db_admin_passwords` | No ADMIN password for that `azure_autonomous_dbs` key. Set `TF_VAR_autonomous_db_admin_passwords` — see [§7.5](#75-azure_autonomous_dbs). |
| Autonomous DB rejects the ADMIN password | 12–30 chars, upper + lower + digit, no `"`, and it may not contain the word `admin`. |
| `compute_count` rejected on an Autonomous DB | Minimum is **2** ECPUs on the ECPU compute model. |
| Autonomous DB `db_version` not available | `19c` and `23ai` are not offered in every region, and availability differs by workload. Check the region before applying. |
| Apply seems to hang for a long time | Expected — the VM cluster (4–8h) dominates; the infra finishes in ~15–20 min and then waits. See [§6.2](#62-provisioning-time). |

Validate before applying:

```bash
terraform fmt -recursive
terraform validate
```

---

## 14. FAQ

**Do I ever edit the `.tf` files?**
Only for things the maps don't expose (custom backends, advanced VM-cluster fields, custom maintenance
windows). Routine work — more clusters, different sizes — is all in `terraform.tfvars`.

**Can I run this with OpenTofu?**
Yes. Replace `terraform` with `tofu`; OpenTofu resolves `hashicorp/azurerm` from its own registry.

**Why doesn't it create the resource group?**
Resource groups are usually governed centrally (policy, naming, RBAC). The blueprint takes an existing
one so it slots into your environment cleanly. Add an `azurerm_resource_group` resource to `main.tf`
if you'd rather Terraform own it.

**Autonomous Serverless or a VM cluster?**
Serverless if you want a managed database in minutes with no infrastructure to size, patch or pay
for while idle — Oracle runs the fleet and you rent ECPUs. A VM cluster (Dedicated) if you need
control of the Exadata hardware, OS-level access, custom CDB/PDB layouts, or Data Guard between
clusters. They are independent maps in the same blueprint, so you can run either or both.

**Can I deploy only Autonomous databases?**
Yes. Leave `azure_infras` and `azure_clusters` empty and fill in `azure_vnets` (for a private
endpoint) plus `azure_autonomous_dbs`. The apply takes minutes instead of hours.

**Is “Oracle AI Database” a different `db_version`?**
No — it is Oracle's branding for the 23ai-and-later line, not a separate version string. Set
`db_version = "23ai"`, which is this blueprint's default; the AI features (AI Vector Search, Select
AI, JSON Relational Duality) come with that release. The field is deliberately unvalidated, so when
your region offers a newer release you set it in `terraform.tfvars` without touching a `.tf` file.
Availability varies by region and workload — check before you apply.

**How do I create databases (CDB/PDB) on the cluster?**
Use the cluster `ocid` output with the `oracle/oci` provider. The main Terraflow Studio app can
generate that layer; this blueprint stops at the VM cluster.

**Is the state safe to commit?**
No — `terraform.tfstate` can contain sensitive values. Use a remote backend and keep state out of git.
