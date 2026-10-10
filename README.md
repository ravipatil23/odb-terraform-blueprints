# Oracle Database@Cloud — Reusable Terraform Blueprints

Hand-fillable, standalone Terraform for **Oracle Database@AWS / @Azure / @GCP**, the
**OCI database stack** (DB Home/CDB/PDB), and **Data Guard** (multi-AZ and cross-region).
These are plain `.tf` files you copy and run — no code generation, no framework.
**You only edit `terraform.tfvars`.**

```
  # ── Provision the cloud infrastructure (network → infra → VM cluster) ──
  db-at-aws/                Oracle Database@AWS    (ODB Network → Exadata Infra → VM Cluster, + optional peering)
  db-at-azure/              Oracle Database@Azure  (optional Resource/Network Anchor → VNet → Exadata Infra → VM Cluster,
                                                   + optional Autonomous Database Serverless off the same VNet)
  db-at-gcp/                Oracle Database@GCP    (ODB Network → Exadata Infra → VM Cluster,
                                                   + optional Autonomous AI Database Serverless off an ODB Network)

  # ── Layer the database on an existing VM cluster ──
  oci-database/             DB Home → CDB → optional PDB, + optional custom NSGs (oracle/oci)

  # ── Data Guard networking between two existing VM clusters ──
  multi-az-dataguard/       Same-region DR  (LPG-peered: LPG pair + NSG rules)
  cross-region-dataguard/   Cross-region DR (Hub VCN + DRG + remote peering)

  # ── DNS ──
  azure-dns-hub/            Custom DNS Scenario #2 — Exadata VCNs → central DNS Hub VCN

  # ── Standalone single-resource templates (pick one, no wiring) ──
  oci-catalog/              db-home · cdb · pdb · nsg · dns-forwarding-rule
```

A typical flow: provision with a `db-at-*` blueprint → create databases with `oci-database`
on the cluster `ocid` it outputs → optionally add a `*-dataguard` blueprint between two clusters.
See [Provisioning sequence](#provisioning-sequence) for the full order and the handoffs between
them, and [How long provisioning takes](#how-long-provisioning-takes) before you plan a window.

[`oci-catalog/`](oci-catalog/) sits apart from that flow. Where the blueprints above are map-driven
and build a whole estate from one apply, the catalog is five **independent** templates — one
resource each, no `for_each`, no wiring. You paste the parent OCID and apply. Use it for one-off
resources or when you want to read exactly what a single resource takes.

## Design

Each `db-at-*` blueprint is a root module that calls small child modules under `modules/`,
driven by **map variables**. To add a second network, infra, or cluster, you add another entry
to the relevant map in `terraform.tfvars` — no `.tf` edits, no copy-paste of resource blocks.
Resources wire together by **map keys**, not hardcoded IDs (e.g. `infra_ref` / `network_key`),
and DB server IDs/OCIDs are **auto-discovered** from the Exadata infrastructure via a data source.

The OCI-layer blueprints take OCIDs of *existing* resources as input:

- **`oci-database`** — chains DB Home → CDB → optional PDB on an existing VM cluster (`vm_cluster_ocid`).
  Also creates optional **custom NSGs** in the cluster's OCI VCN: the cluster lives in OCI whichever
  cloud fronts it, so the rules governing access to the databases are OCI objects and belong here
  rather than in a `db-at-*` blueprint.
- **`multi-az-dataguard` / `cross-region-dataguard`** — build the OCI network path between two
  existing VM cluster VCNs so Data Guard redo can flow. Neither manages the existing cluster VCN
  route tables (you add the one DG route by hand after apply — each README explains).

## Usage

```bash
cd <blueprint>                 # e.g. db-at-aws, oci-database, multi-az-dataguard
# edit terraform.tfvars  (oci-database also takes passwords via TF_VAR_* env vars)
terraform init
terraform plan
terraform apply
```

(OpenTofu works too: `tofu init && tofu plan && tofu apply`.)

## Provisioning sequence

Each blueprint is its **own root module with its own state** — there is no umbrella configuration
that runs them all. You apply them in order, and carry an output from one into the `terraform.tfvars`
of the next. Terraform enforces ordering *inside* a blueprint; **you** enforce it *between* them.

| Phase | Blueprint | Run it when | Takes from the previous phase | Hands on |
|-------|-----------|-------------|-------------------------------|----------|
| 0 | *(none — manual)* | Azure + custom DNS | — | private view + zone per environment |
| 1 | `db-at-aws` / `db-at-azure` / `db-at-gcp` | Always first | phase 0 view, if using custom DNS | VM cluster **`ocid`** |
| 1a | `db-at-azure` / `db-at-gcp` — Autonomous *(alternative)* | You want a managed database, not Exadata hardware | phase 0 view, if using custom DNS | nothing — the sequence ends here |
| 2 | `oci-database` | You need CDBs/PDBs, or NSGs | cluster `ocid` → `vm_cluster_ocid` | `db_homes`, `cdbs`, `pdbs`, `nsgs` |
| 3 | `multi-az-dataguard` / `cross-region-dataguard` | You need DR | both clusters' VCN + NSG OCIDs | LPG / DRG OCIDs → **manual routes** |
| 4 | `azure-dns-hub` | Azure + custom DNS | Exadata VCN OCIDs + phase 0 view OCIDs | hub listening endpoint IP |

Phase **1a** is a fork, not a step: an Autonomous Database Serverless is already a database, so
there is no DB Home / CDB / PDB layer to add and nothing hands off to phase 2. It lives in the same
`db-at-azure` / `db-at-gcp` blueprint and the same apply as phase 1 — you can run both, or leave the
infra and cluster maps empty and run only Autonomous. AWS has no Autonomous branch in these
blueprints.

Phases 2–4 are independent of each other: run any, all, or none. Phase 1 is the only prerequisite
they share. Phases 3 and 4 both finish with a **manual route step** — the apply is not the end of
the job, and each README spells out the rules to add.

> **Phase 0 only applies if you are using Custom DNS on Azure**, and it is easy to miss because it
> runs *before* everything and no blueprint performs it. The OCI private view and its zone must
> exist **before** the VM cluster is provisioned, and the cluster must be created against that view
> — that is what lets the service auto-populate the zone with the SCAN and VIP `A` records
> afterwards. `azure-dns-hub` in phase 4 only *attaches* those views; it does not create them, and
> creating them there would be too late. Get this wrong and you finish with an empty zone and a
> cluster nothing can resolve.

### Phase 1 — provision the cluster

Pick the one blueprint matching your cloud. Inside it, Terraform resolves this order itself from the
module graph — you do not stage it:

On **AWS and GCP** the recommended operational order — the sequence to follow and verify — is:

| # | Step | Typical elapsed |
|---|------|-----------------|
| 1 | **Exadata infrastructure** | ~15–20 min |
| 2 | **ODB network** | up to ~4 h |
| 3 | **Peering** *(AWS only, optional)* | ~15–20 min |
| 4 | **VM cluster** | ~4–8 h |

**Terraform does not enforce steps 1 and 2 relative to each other.** The infra takes no argument from
the ODB network, so they are independent branches the graph is free to run **concurrently**; only the
convergence at the VM cluster is a real dependency. In practice they line up anyway — the infra
finishes in ~20 minutes and the network takes hours.

```
db-at-aws     exadata_infra ──▶ [data.aws_odb_db_servers] ─┬──▶ vm_cluster
              odb_network ─────────────────────────────────┘
                    └──▶ peering  (optional; starts once odb_network is up)

db-at-gcp     exadata_infra ──▶ [data.google_..._db_servers] ─┬──▶ vm_cluster
              odb_network ────────────────────────────────────┘
                    └────────────────────────────────────────────▶ autonomous_db  (optional)
              odb_network_adbs ───────────────────────────────────┘  (client subnet only)

db-at-azure   resource_anchor ──▶ exadata_infra ─┐
              vnet ──▶ network_anchor ───────────┴──▶ vm_cluster
                  └──────────────────────────────────▶ autonomous_db  (optional, ~5-15 min)
```

**Autonomous Database Serverless** is available on both `db-at-azure` and `db-at-gcp`, and on
neither does it need an Exadata infrastructure — Oracle runs the fleet. On Azure a stack with
`azure_infras` and `azure_clusters` left empty builds in **minutes**; on GCP the ODB network is
still the long pole, but the 4–8h VM cluster drops out. Either way the sequence ends there: a
Serverless database is already a database, so nothing hands off to `oci-database`.

The two differ in one respect worth knowing before you pick. On GCP, eight fields — `compute_count`
and `data_storage_size_gb` among them — sit under an `ignore_changes` guard because Autonomous
scaling rewrites them in place, so **resizing is not a tfvars edit**. On Azure the same resize is a
plain in-place update. GCP also splits the network in two: `gcp_odb_networks_adbs` builds a client
subnet without the backup subnet only VM clusters use.

One apply covers every step; the order is what you watch, not something you stage.

```bash
cd db-at-aws                  # or db-at-azure / db-at-gcp
terraform init && terraform apply
terraform output vm_clusters  # ◀── the ocid you need next
```

> One apply covers the whole phase. Do **not** try to `-target` the infra first and the cluster
> after: the DB-server data source is what wires them together, and targeting skips it.

### Phase 2 — create databases

Feed the cluster OCID from phase 1 into `oci-database`:

```bash
cd ../oci-database
# terraform.tfvars: vm_cluster_ocid = "<ocid from phase 1>"
export TF_VAR_admin_password=...      # keys must match the maps in terraform.tfvars
export TF_VAR_pdb_admin_password=...
terraform init && terraform apply
```

Internally this chains **DB Home → CDB → PDB** (`depends_on` at each step), so one apply builds the
whole stack. Add more homes/CDBs/PDBs later by adding map entries and re-applying.

### Phase 3 — Data Guard (optional)

Requires **two** clusters from phase 1 — so run phase 1 twice, in two AZs/ADs (`multi-az-dataguard`)
or two regions (`cross-region-dataguard`), before starting here. Collect each cluster's VCN OCID,
NSG OCID and client subnet CIDR, then apply. **Afterwards you add one route per VCN by hand** —
neither blueprint manages the existing cluster route tables. Cross-region auth must work in *both*
regions.

### Phase 4 — DNS hub (optional, Azure)

`azure-dns-hub` wires existing Exadata VCNs to a central hub VCN. It **attaches** each environment's
private view from phase 0 to the hub resolver — it does not create views or zones, so those OCIDs
are an input, not an output. Also finishes with **two manual route rules**, one per side.

## How long provisioning takes

Phase 1 is measured in **hours, not minutes** — plan a window and do not interrupt an apply
mid-flight. Note which resources are actually slow: it is **not** the ones you would guess.

| Phase | What is being built | Typical elapsed | Module timeout ceiling |
|-------|--------------------|-----------------|------------------------|
| 1 | Exadata infrastructure | ~15–20 min | 6h create (Azure); provider default (AWS/GCP) |
| 1 | **ODB network** (AWS/GCP) | **up to ~4 h** | 12h create · 2h update · 8h delete |
| 1 | ODB network peering *(AWS only, optional)* | ~15–20 min | provider default |
| 1 | VNet + delegated subnet (Azure) | ~2–5 min | provider default |
| 1 | Resource Anchor (Azure only) | ~10–30 min | 1h create · 1h delete |
| 1 | Network Anchor (Azure only) | ~10–30 min | provider default |
| 1 | **VM cluster** | **~4–8 h** | 12h create · 2h update · 8h delete |
| 1 | **Full apply (critical path)** | **~8–12 h** (AWS/GCP) · **~5–9 h** (Azure) | — |
| 2 | DB Home + first CDB | ~30–60+ min | provider default |
| 2 | Additional CDB / PDB | ~15–30 min each | provider default |
| 3 | Data Guard networking (LPG/DRG/NSG) | ~5 min | provider default |
| 4 | DNS hub links | ~5 min | provider default |

**The Exadata infrastructure is the fastest thing in the build, not the slowest.** The hardware
provisions in 15–20 minutes; the two long poles are the **ODB network** (up to 4 h) and the **VM
cluster** (4–8 h). Budget on those two and nothing else will surprise you.

Because the network and the infra run concurrently, the critical path skips the infra entirely:

```
odb_network (≤4 h) ─────────────┬──▶ vm_cluster (4–8 h)   ≈ 8–12 h total
exadata_infra (15–20 min) ──────┘
                └──▶ peering (15–20 min, off the critical path)
```

The infra sitting "done" while the apply keeps running for hours is expected — the cluster is
waiting on the network branch, not the hardware.

**Plan phase 1 across two days, or start it early.** At 8–12 hours it does not fit in a business
day, and phase 2 (~30–60 min) cannot start until it finishes. Phases 3 and 4 are minutes.

Two different numbers above, do not confuse them:

- **Typical elapsed** comes from observed runs. It is still a range, not a guarantee — real time
  varies with shape, `compute_count` / `storage_count`, region, and current capacity in the AZ.
- **Timeout ceiling** is exact — it is the `timeouts` block in that module's `main.tf`, the point at
  which Terraform gives up and errors. It is a limit, *not* an estimate. Where the table says
  "provider default", the module sets none and the provider's own default applies.

Timing notes:

- **A slow apply is normal.** Terraform prints `Still creating... [10m0s elapsed]` throughout. Every
  blueprint's Troubleshooting section lists "apply seems to hang" as expected behaviour.
- **Destroy is not faster.** Delete ceilings are 8h (networks, clusters) and 3h (Azure infra).
- **Time your own runs** to confirm the ranges above hold for your shape and region:
  ```bash
  time terraform apply -auto-approve
  # or per-resource:
  TF_LOG=INFO terraform apply 2>&1 | grep -E "Creation complete|Still creating"
  ```
- **Scaling is not free.** Every VM cluster argument is ForceNew — a change Terraform cannot do
  in place proposes *replacement*, paying the multi-hour cluster build again. That is exactly why
  the `db-at-*` modules carry `prevent_destroy` and `ignore_changes` guards.

## Provider versions

| Blueprint | Provider | Version |
|-----------|----------|---------|
| db-at-aws | `hashicorp/aws`     | `>= 6.42.0` |
| db-at-azure | `hashicorp/azurerm` | `>= 4.51.0` |
| db-at-azure (Network Anchors) | `Azure/azapi` | `>= 2.8.0` |
| db-at-gcp | `hashicorp/google`  | `>= 7.5.0`  |
| oci-database | `oracle/oci` | `>= 7.11.0` |
| multi-az-dataguard | `oracle/oci` | `>= 6.0.0` |
| cross-region-dataguard | `oracle/oci` | `>= 6.0.0` |
| azure-dns-hub | `oracle/oci` | `>= 6.0.0` |

Each floor is the oldest release the blueprint actually validates against — CI's **floor** job
(see [CI](#ci)) pins exactly these versions, so raise the floor whenever a blueprint starts using a
newer argument. Provider requirements are static, so a floor applies even when the map that needs
the newer argument is empty.

Terraform `>= 1.5.0` (or OpenTofu `>= 1.6.0`) — the map variables use optional object attributes.

## Authentication (set before `terraform apply`)

- **AWS** — standard AWS credential chain (`aws configure`, `AWS_PROFILE`, env vars, or an instance role).
- **Azure** — `az login`, plus `subscription_id` in `terraform.tfvars`. The resource group must already exist.
- **GCP** — `gcloud auth application-default login` (or `GOOGLE_APPLICATION_CREDENTIALS`), plus `gcp_project`.
- **OCI blueprints** (`oci-database`, `*-dataguard`) — OCI auth via `~/.oci/config` or `OCI_*` env vars.
  Cross-region Data Guard must be authorized in **both** regions; `oci-database` takes DB passwords via
  `TF_VAR_admin_password` / `TF_VAR_pdb_admin_password`.

See each blueprint's own `README.md` for cloud-specific notes and gotchas.

## CI

`.github/workflows/validate.yml` runs `terraform fmt -check -recursive` once, then
`terraform validate` against each blueprint as a separate matrix job — every blueprint is
its own root module. No cloud credentials are needed: `-backend=false` skips state, and
`validate` only needs the providers that `init` pulls from the registry.

Each blueprint is validated twice:

- **latest** — a plain `init`. Constraints are floor-only and lock files are not committed, so
  this is the newest provider a user copying the blueprint would get today.
- **floor** — Terraform `1.5.0` and every provider pinned to the blueprint's declared `>= X`
  (via [`.github/scripts/pin_floor.py`](.github/scripts/pin_floor.py)), so the table above stays true.

### Keeping up with provider releases

Two scheduled jobs run every Monday, so provider releases surface even when nobody pushes:

- **`validate.yml`** re-runs the matrix above. If a new release breaks a blueprint (latest) or a
  blueprint quietly depends on something newer than its floor, it opens a `provider-drift` issue,
  or comments on the open one.
- **`provider-schemas.yml`** regenerates [`.github/provider-schemas/`](.github/provider-schemas/):
  one line per argument of every resource and data source the blueprints use, plus whole Oracle
  families (`aws_odb_*`, `azurerm_oracle_*`, `google_oracle_database_*`) so new resources appear.
  If anything changed, it opens a pull request whose diff *is* the changelog — new arguments,
  `DEPRECATED` markers, newly `required` arguments, removals. Merge it to accept the new baseline,
  then expose anything useful in the blueprint in a normal pull request.

To refresh the snapshots locally: `python .github/scripts/provider_schemas.py [aws azurerm google oci]`.
