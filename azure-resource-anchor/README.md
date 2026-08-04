# Oracle Database@Azure — Resource Anchor — Terraform Blueprint

Standalone Terraform that provisions an **Oracle Database@Azure Resource Anchor** — the
**foundational prerequisite** for everything else on Database@Azure. A Resource Anchor maps
an Azure resource group to an **OCI compartment**; the Network Anchor, Exadata
infrastructure and VM clusters all require one to exist first. You only edit
[`terraform.tfvars`](terraform.tfvars).

> **Native provider.** Unlike the [`azure-network-anchor`](../azure-network-anchor) blueprint
> (which uses `azapi` because `azurerm` has no resource for it), the Resource Anchor has a
> **native** azurerm resource —
> [`azurerm_oracle_resource_anchor`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/oracle_resource_anchor) —
> so this blueprint uses it directly.

---

## 1. What this deploys

| Resource | Type | Provider |
|----------|------|----------|
| Resource Anchor | `azurerm_oracle_resource_anchor` (`Oracle.Database/resourceAnchors`) | `hashicorp/azurerm` |

Creating it links (or creates) an **OCI compartment** for the resource group. Its region and
the linked compartment OCID are assigned by the service and surfaced as outputs — you do not
set a location; the anchor inherits it from the resource group.

**Provider:** `hashicorp/azurerm >= 4.9.0` · **Terraform:** `>= 1.5.0` (or OpenTofu `>= 1.6.0`).

---

## 2. Prerequisites

1. An **existing resource group** in a region that offers Oracle Database@Azure, and IAM
   rights on it.
2. An active **Oracle Database@Azure onboarding** (the Azure↔OCI link established via the
   Azure Marketplace/portal for your tenancy).
3. **Terraform `>= 1.5.0`** and the `azurerm` provider (pulled automatically).

---

## 3. Authentication

```bash
az login
az account set --subscription "00000000-0000-0000-0000-000000000000"
# or service principal: export ARM_CLIENT_ID / ARM_CLIENT_SECRET / ARM_TENANT_ID / ARM_SUBSCRIPTION_ID
```

Set the same `subscription_id` in `terraform.tfvars`.

---

## 4. Quick start

```bash
cd blueprints/azure-resource-anchor

# 1. az login  (see §3)
# 2. edit terraform.tfvars — subscription, and per anchor: name + resource_group_name

terraform init
terraform plan
terraform apply
```

---

## 5. Variable reference

Top level: `subscription_id` (required) and the `resource_anchors` map.

**`resource_anchors` entry fields:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | ✅ | Resource Anchor name. |
| `resource_group_name` | string | ✅ | Existing resource group the anchor maps to an OCI compartment. |
| `tags` | map(string) | — | Resource tags. Default `{}`. |

---

## 6. Outputs

| Output | Notes |
|--------|-------|
| `resource_anchors` | Map keyed by your map key → `{ id, location, linked_compartment_id }`. Feed `id` into the [`azure-network-anchor`](../azure-network-anchor) blueprint's `resource_anchor_id`. |

```bash
terraform output resource_anchors
```

---

## 7. Notes & gotchas

- **Order:** create the Resource Anchor **first**, then the delegated subnet + Network Anchor,
  then Exadata infrastructure / VM clusters.
- **No location input** — the anchor inherits its region from the resource group; `location`
  comes back as an output.
- **Renaming a map key** destroys and recreates that anchor (Terraform identity is the key).
- **OpenTofu** works — replace `terraform` with `tofu`.

---

## 8. Destroying

```bash
terraform destroy
```

Removes the Resource Anchor(s). Destroy any Network Anchors, Exadata infrastructure and VM
clusters that depend on an anchor **before** destroying it.
