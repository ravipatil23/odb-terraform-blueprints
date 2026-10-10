# OCI Catalog — standalone single-resource templates

A catalog of **independent** Terraform templates, one per OCI resource type. Pick the one you need,
fill in its `terraform.tfvars`, apply. Each is a complete root module with its own state.

**No dependency wiring.** Where a resource needs a parent, you paste that parent's OCID as a plain
input. Nothing here references anything else here — no `for_each`, no map keys, no cross-module
plumbing. That is the point: each template does one thing, and you compose them by copying OCIDs.

> This is deliberately **not** [`oci-database`](../oci-database). That blueprint is map-driven and
> builds a whole estate from one apply, wiring homes → CDBs → PDBs by key. These templates are the
> opposite trade: one resource, one apply, no wiring, easy to read and to run ad hoc.

---

## The catalog

| Template | Creates | Needs | Gives you |
|----------|---------|-------|-----------|
| [`db-home/`](db-home/) | Database Home | `vm_cluster_ocid` | `db_home_id` |
| [`cdb/`](cdb/) | Container Database | `db_home_id` | `cdb_id` |
| [`pdb/`](pdb/) | Pluggable Database | `container_database_id` | `pdb_id` |
| [`nsg/`](nsg/) | Network Security Group + rules | `compartment_id`, `vcn_id` | `nsg_id`, `forwarder_attach_command` |
| [`dns-forwarding-rule/`](dns-forwarding-rule/) | FORWARD rules on an existing resolver | `resolver_id`, `source_endpoint_name` | `rules_before_apply` |

The database three chain by OCID if you want them to — `db_home_id` from one becomes the input to
the next — but each stands alone. Use `cdb/` against a DB Home someone else created and it neither
knows nor cares.

`nsg/` and `dns-forwarding-rule/` are independent of the database ones entirely. They act on the VCN,
so they apply whichever cloud provisioned the cluster — AWS, Azure, GCP or native OCI.

`dns-forwarding-rule/` writes the FORWARD rules, and can go either way on the endpoint:

| `create_forwarder` | Endpoint | Can it attach an NSG? |
|---|---|---|
| `false` *(default)* | referenced — made by other tooling | **No.** `nsg_ids` belongs to the endpoint, and Terraform only sets attributes of resources it manages. Use `nsg/`'s `forwarder_attach_command`. |
| `true` | created here, with `forwarder_subnet_id` | **Yes** — `forwarder_nsg_ids` attaches it at creation. No CLI step. |

That second row is the tidiest path when you control both: `nsg/` outputs `nsg_id`, which goes
straight into `forwarder_nsg_ids` here. Owning the endpoint is what makes the attach declarative.

Two `check` blocks keep the modes honest — `create_forwarder = true` without a subnet, and
`forwarder_nsg_ids` supplied while referencing an endpoint (where it would silently do nothing).

It takes the **resolver** OCID directly rather than discovering it from a VCN. The
`oci_core_vcn_dns_resolver_association` lookup can return `null` rather than erroring — for a wrong
region, or a VCN the credentials cannot see — which surfaces as an opaque `coalesce failed` with no
hint about the cause. One extra OCID is cheaper than that:

```bash
oci dns resolver list --compartment-id <comp> --scope PRIVATE \
  --query 'data[].{name:"display-name",id:id,vcn:"attached-vcn-id"}' --output table
```

---

## File layout

Every template uses the same flat structure, so you always know where to look:

```
<template>/
├── providers.tf       # terraform{} + provider{} — identical in all five
├── main.tf            # the resource(s), and any check blocks
├── data.tf            # data sources — only where a template has them
├── variables.tf       # inputs
├── outputs.tf         # what you carry to the next template
└── terraform.tfvars   # ◀── YOU EDIT THIS
```

`data.tf` exists only in `dns-forwarding-rule/`; the others have no data sources. None of them
declare `locals` — every value is either an input or read straight off a resource.

---

## Running one

```bash
cd oci-catalog/db-home        # or cdb, pdb, nsg, dns-forwarding-rule

# auth once per shell
oci setup config              # ~/.oci/config, or OCI_* env vars

# passwords for cdb / pdb — never in tfvars
export TF_VAR_admin_password='YourStr0ng#Pass'

# edit terraform.tfvars, then
terraform init
terraform plan
terraform apply
terraform output
```

Each directory keeps its **own state file**. Running `db-home/` and `cdb/` gives you two independent
states — destroying one does not touch the other, which is the trade you are making for the lack of
wiring.

---

## Chaining them by hand

```bash
cd db-home && terraform apply
HOME_ID=$(terraform output -raw db_home_id)

cd ../cdb
# put $HOME_ID into terraform.tfvars as db_home_id
export TF_VAR_admin_password='YourStr0ng#Pass'
terraform apply
CDB_ID=$(terraform output -raw cdb_id)

cd ../pdb
# put $CDB_ID into terraform.tfvars as container_database_id
export TF_VAR_pdb_admin_password='YourStr0ng#Pass'
terraform apply
```

Because nothing is wired, **Terraform will not stop you deleting a parent out from under a child.**
Destroying `db-home/` while `cdb/` still holds a database in it fails at the API, not at plan.
Destroy in reverse: PDB → CDB → DB Home.

If you want that ordering enforced for you, use [`oci-database`](../oci-database) instead — it
carries `depends_on` between the layers and tears down in the right order automatically.

---

## Things worth knowing before you apply

**Passwords never go in tfvars.** `cdb/` and `pdb/` read them from `TF_VAR_admin_password` and
`TF_VAR_pdb_admin_password`. Oracle's rules: 9–30 characters, at least 2 uppercase, 2 lowercase,
2 digits and 2 special characters, and not the database name.

**`nsg/` creates the NSG but does not attach it.** There are two things you might attach it to, and
neither is something Terraform can do here — `nsg_ids` is an attribute of the target resource, and
Terraform can only set attributes of resources it manages. Both targets are owned by other tooling.

*To the DNS forwarding endpoint* — set `resolver_id` in the template's tfvars and it builds the
command for you, with the endpoint located automatically and any NSG already on it carried through:

```bash
terraform output -raw forwarder_attach_command
# oci dns resolver-endpoint update --resolver-id ocid1.dnsresolver... \
#   --resolver-endpoint-name prodOnpremFwd --scope PRIVATE --force \
#   --nsg-ids '["ocid1.networksecuritygroup..."]'
```

Leave `resolver_id` unset and the output tells you so rather than emitting a broken command. If the
resolver has no forwarding endpoint, it says that too, with the command to check.

*To the VM cluster* — no `vm-cluster` resource on AWS, Azure or GCP takes an NSG argument, so that
one is a manual step against the cluster. `--nsg-ids` **replaces** the whole list, so read it first
and append:

```bash
NSG=$(terraform output -raw nsg_id)
EXISTING=$(oci db cloud-vm-cluster get --cloud-vm-cluster-id "$CLUSTER" \
  --query 'data."nsg-ids"' --raw-output)

oci db cloud-vm-cluster update --cloud-vm-cluster-id "$CLUSTER" --force \
  --nsg-ids "$(echo "${EXISTING:-null}" | jq -c --arg n "$NSG" '(. // []) + [$n] | unique')"
```

**`dns-forwarding-rule/` adopts the VCN's resolver.** Resolvers are born with their VCN and cannot be
created, so a plan saying `oci_dns_resolver.this will be created` means Terraform is taking over the
existing one. Three consequences:

- **Your `rules` list replaces every rule on the resolver.** The API writes the array as a unit — it
  does not append — so anything already there and not repeated in your list is removed. This is the
  single most important thing to get right. Read first:
  `oci dns resolver get --resolver-id <ocid> --scope PRIVATE --query 'data.rules'`
  The template also exports `rules_before_apply`, which captures what was there so you can compare.
- **Destroy clears rules rather than deleting the resolver.** The resolver survives; the forwarding
  it was doing stops.
- **The endpoint must already exist.** A `check` block confirms `source_endpoint_name` is present on
  the resolver at plan time and lists the real endpoint names if it isn't — rather than letting a
  typo reach the API.

**Renaming a key in `nsg/`'s `rules` map** destroys and recreates that rule — a brief gap in what it
enforces. Change the `description` instead if you only want a better label.
