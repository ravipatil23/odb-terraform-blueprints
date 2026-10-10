# Database@Azure — Custom DNS, Scenario #2 (Network Anchor as DNS Hub)

Terraform that wires one or more **Exadata VM cluster VCNs** to a central **DNS Hub VCN**
(the Network Anchor), implementing Scenario #2 from the A-Team article
*“Custom DNS for Oracle AI Database@Azure”* and the Oracle docs
*“DNS for Oracle AI Database@Azure”*. You only edit [`terraform.tfvars`](terraform.tfvars).

Two limits bound how far one hub stretches — both come from **Local Peering Gateways**, which is
how the hub links to each VCN:

> **Same-region only.** The DNS hub and every VM cluster VCN it serves live in one OCI region —
> the single `region` in `terraform.tfvars`. LPG peering does not cross regions, and there is no
> DRG or Remote Peering Connection here.
>
> For databases in several regions, run **one hub per region**: a separate copy of this blueprint,
> with its own Network Anchor and its own state.

> **~10 VM cluster VCNs per hub.** LPG peering is 1:1, so every environment consumes one LPG **on
> the hub VCN**. A VCN's LPG limit — **10** by default — therefore caps how many VCNs a single hub
> can serve, and the hub hits that ceiling before any spoke does.
>
> Exceeding it **warns at plan time** rather than failing, because the limit is raisable: request
> an increase, then set `hub_lpg_limit` to match. Past that, split across a second hub.

---

## Table of contents

1. [What this deploys](#1-what-this-deploys)
2. [Architecture](#2-architecture)
3. [Prerequisites](#3-prerequisites)
4. [Authentication](#4-authentication)
5. [Repository layout](#5-repository-layout)
6. [Quick start](#6-quick-start)
7. [Variable reference](#7-variable-reference)
   - [Top-level](#71-top-level-variables)
   - [`environments`](#72-environments)
   - [When the VCNs are already peered](#73-when-the-vcns-are-already-peered)
   - [Extra FORWARD rules on the hub resolver](#74-extra-forward-rules-on-the-hub-resolver)
8. [Security list rules](#8-security-list-rules)
9. [Routing — manual, by design](#9-routing--manual-by-design)
   - [The two rules](#91-the-two-rules)
   - [Getting the values](#92-getting-the-values)
   - [Adding them](#93-adding-them)
   - [Checking it worked](#94-checking-it-worked)
10. [Outputs](#10-outputs)
11. [Adding another VM cluster VCN](#11-adding-another-vm-cluster-vcn)
12. [Destroying](#12-destroying)
13. [Troubleshooting](#13-troubleshooting)

---

## 1. What this deploys

Per environment (e.g. `prod`, `nonprod`) — one entry = one VM cluster VCN:

| # | Resource | Purpose |
|---|----------|---------|
| 1 | `oci_core_local_peering_gateway` ×2 | 1:1 LPG pair (VM cluster VCN ⇄ Hub VCN). Peering is strictly 1:1, so **each environment gets its own pair**. |
| 2 | `oci_dns_resolver_endpoint` (forwarding) | Forwarding endpoint on the VM cluster VCN resolver — egress queries from the databases. |
| 3 | `oci_dns_resolver` rule (`FORWARD`) | Sends the configured Azure domains to the hub **listening** endpoint. |
| 4 | `oci_core_default_security_list` *(optional)* | DNS rules on the **default security list you name** for this environment's resolver subnet — broad UDP/TCP 53, egress and ingress. Already attached to the subnet, so nothing to wire up. Skipped when `resolver_security_list_id` is omitted. |

Once at the hub — whatever the environment count:

| # | Resource | Purpose |
|---|----------|---------|
| 5 | `oci_dns_resolver_endpoint` (listening) | The hub **listener**. Created here, not by the anchor — see the callout below. Skipped when `create_hub_listening_endpoint = false`. |
| 6 | `oci_dns_resolver` `attached_views` | Attaches **every environment's existing private views** to the hub resolver, so the listener can answer Azure's queries for those database hostnames. |
| 7 | `oci_dns_resolver` `rules` *(optional)* | Extra FORWARD rules on the hub resolver, from `hub_resolver_forward_rules`. **Not emitted at all when that map is empty** — see [7.4](#74-extra-forward-rules-on-the-hub-resolver). |
| 8 | `oci_core_default_security_list` *(optional)* | DNS rules on the **default security list you name** for the hub resolver subnet — broad UDP/TCP 53 ingress. Skipped when `hub_resolver_security_list_id` is omitted. |

**Provider:** `oracle/oci >= 6.0.0` · **Terraform:** `>= 1.5.0` (or OpenTofu `>= 1.6.0`).

### What this deliberately does *not* create

Four things belong to the platform or to an earlier lifecycle stage. Creating them here would
produce empty, duplicate or redundant objects:

| Not created | Owned by | Why |
|---|---|---|
| Hub **forwarding** endpoint | Network Anchor | `isOracleDnsForwardingEndpointEnabled` provisions it, and the control plane adds the anchor's `dnsForwardingRules`. The hub's OCI→Azure egress is the anchor's job. |
| The anchor's **own NSG** | Network Anchor | It already allows **0.0.0.0/0 on port 53** on the delegated subnet. Nothing here writes to it. The security lists above govern the *resolver* subnets, which are yours — a different subnet, and the anchor's blanket rule does not cover them. |
| Private **views** and **zones** | You, before cluster provisioning | They must pre-date the VM cluster, which is what lets the service auto-populate SCAN/VIP records. Creating them here yields empty zones. |
| Resolver **route rules** | You, by hand after apply | See [§9](#9-routing--manual-by-design). |

**Port 53 is governed by security lists, not NSGs.** You name the **default security list** on
each resolver subnet — `hub_resolver_security_list_id` for the hub, `resolver_security_list_id` per
environment — and the DNS rules are written into it. That list is already attached to its subnet, so
there is nothing to wire up afterwards. Omit an OCID to write that subnet's port-53 rules yourself.

> **Why not NSGs.** An NSG has to be attached to the resolver **endpoints**, via `nsg_ids` on
> `oci_dns_resolver_endpoint`. That ties every rule's identity to an object this configuration
> creates and replaces — change the NSG and Terraform destroys each rule on the old one and creates
> it on the new. A security list governs the **subnet**, so the endpoints inside it are untouched by
> the rules protecting them.

> **Port 53 is opened broadly**, from `0.0.0.0/0` — the same posture as the Network Anchor's own
> NSG. Everything that legitimately queries these listeners is a resolver: each spoke's forwarding
> endpoint over its LPG, and Azure's private resolver. Enumerating those CIDRs bought a list to keep
> in step with every new spoke and every Azure-side change, and a silent outage whenever it fell
> behind. Reaching an endpoint still requires a route and a peering.

> **⚠ The rule set is authoritative.** The OCI API replaces a security list's rules wholesale, so
> what this blueprint declares **is** the list after apply — anything else on it today is removed.
> Inspect each one before the first apply:
>
> ```bash
> oci network security-list get --security-list-id <ocid> >   --query 'data.{ingress:"ingress-security-rules",egress:"egress-security-rules"}'
> ```
>
> `allow_all_egress` (default `true`) re-states the egress-all rule a default list normally carries,
> so leaving it on preserves that much.

> **Private views and zones are referenced, not created.** With Custom DNS the private view and its
> zone must exist **before** the VM cluster is provisioned — the cluster is created against that
> view, and the service then auto-populates it with the SCAN and VIP `A` records. Supply each
> environment's existing view OCIDs as `view_ids`.

---

## 2. Architecture

```
                       ┌────────────────────────────┐
  Azure private  ───▶  │  DNS Hub VCN (Network      │
  resolver / VNets     │  Anchor)                   │
                       │   • LISTENING endpoint ◀───┼── this blueprint
                       │   • FORWARDING endpoint ───┼── anchor-created
                       │   • per-env views ATTACHED │ ◀── this blueprint
                       └───────┬─────────────┬──────┘
                       LPG 1:1 │             │ LPG 1:1
                  ┌────────────▼──┐      ┌───▼────────────┐
                  │ VM cluster VCN│      │ VM cluster VCN │
                  │   (prod)      │      │   (nonprod)    │
                  │  FORWARD ep ──┼──────┼─▶ hub listener │
                  └───────────────┘      └────────────────┘
```

Everything resolves **through the hub**, in both directions:

```
Inbound   Azure private resolver ─▶ Hub LISTENING endpoint ─▶ attached views ─▶ OCI private IPs
Outbound  Database ─▶ VCN FORWARDING endpoint ─▶ FORWARD rule ─▶ Hub LISTENING endpoint
```

The map in `terraform.tfvars` is joined by **keys** — one key per VM cluster VCN, each carrying its
own VCN, resolver subnet and view OCIDs.

---

## 3. Prerequisites

1. **A Network Anchor and its DNS hub VCN**, created with the **listening endpoint flag off**
   (`isOracleDnsListeningEndpointEnabled = false`) — the hub's listener is created here instead.
   Enable `isOracleDnsForwardingEndpointEnabled` on it if the hub VCN itself must resolve Azure
   FQDNs; that endpoint and its forwarding rules stay the anchor's.
2. **A resolver subnet in the hub VCN** to host the listening endpoint — its OCID as
   `hub_resolver_subnet_id`, its CIDR as `hub_resolver_subnet_cidr`, and its **default security
   list** as `hub_resolver_security_list_id`. A subnet of your own, not the one delegated to the
   anchor.
3. **One Exadata VM cluster VCN per environment**, each with a resolver subnet to host its own
   forwarding endpoint, and that subnet's default security list as `resolver_security_list_id`.
4. **One or more private views + zones per VM cluster VCN**, created **before** that VCN's cluster
   was provisioned and selected as its Custom DNS view. SCAN and VIP `A` records are auto-populated
   into the zone afterwards. You supply the OCIDs as `view_ids`.
5. **Non-overlapping** resolver subnet CIDRs between the hub and every spoke.
6. **IAM** to manage `virtual-network-family` and `dns-family` in the compartment.
7. **Terraform `>= 1.5.0`** — the configuration uses optional object attributes and `check` blocks.

All of these live in **one region** (see the callout at the top).

---

## 4. Authentication

The provider block sets only the region; credentials come from your OCI config:

```bash
oci setup config        # ~/.oci/config
# or export OCI_CLI_USER / OCI_CLI_TENANCY / OCI_CLI_FINGERPRINT / OCI_CLI_KEY_FILE / OCI_CLI_REGION
export TF_VAR_compartment_id="ocid1.compartment.oc1..."
```

---

## 5. Repository layout

```
azure-dns-hub/
├── main.tf              # hub-side wiring + per-env module calls (no need to edit)
├── variables.tf         # variable definitions (no need to edit)
├── outputs.tf           # outputs (no need to edit)
├── terraform.tfvars     # ◀── YOU EDIT THIS
└── modules/
    └── exadata-dns-link/   # per-VCN wiring: LPG pair, forwarding endpoint, FORWARD rule, DNS rules
```

---

## 6. Quick start

```bash
cd azure-dns-hub

# 1. authenticate to OCI (see §4)
# 2. edit terraform.tfvars — region, compartment, hub OCIDs (VCN + resolver
#    subnet), its CIDR and its default security list OCID, and one
#    environments entry per
#    VM cluster VCN (including its view_ids)

terraform init
terraform plan           # review; also surfaces the LPG-limit warning if any
terraform apply

# 3. add the two route rules per VCN by hand (see §9)
```

**Timing: ~5 minutes.** LPGs, resolver endpoints, forwarding rules and security list rules — no hardware.
That is a different order of magnitude from the multi-hour cluster build in `db-at-azure`.

After apply, point Azure's DNS forwarding ruleset at the hub listener:

```bash
terraform output hub_listening_endpoint_ip
```

> **Where this sits in the sequence.** This runs *last*, against VCNs and a hub that already exist.
> But **one prerequisite runs much earlier**: the private views and zones it attaches must be
> created *before* their VM clusters are provisioned, and selected as each cluster's Custom DNS
> view at creation time. That step sits ahead of `db-at-azure`, not here — this blueprint only
> consumes the result, which is why it can safely run last.

---

## 7. Variable reference

### 7.1 Top-level variables

| Variable | Type | Required | Description |
|----------|------|----------|-------------|
| `region` | string | ✅ | OCI region holding the hub **and** every VM cluster VCN. Same-region only. |
| `compartment_id` | string | ✅ | Compartment OCID holding the VCNs, LPGs and DNS objects. |
| `hub_vcn_id` | string | ✅ | OCID of the central DNS Hub VCN (the Network Anchor's VCN). |
| `hub_resolver_subnet_cidr` | string | ✅ | CIDR of the hub resolver subnet. Used in the spoke-side security list rules. |
| `hub_resolver_subnet_id` | string | ✅¹ | Subnet in the hub VCN that hosts the **listening endpoint**. Required while `create_hub_listening_endpoint` is `true` (the default); a precondition fails the plan without it. |
| `hub_resolver_id` | string | — | Hub VCN system resolver OCID. **Discovered from the VCN when `null`** (default). |
| `create_hub_listening_endpoint` | bool | — | Create the hub listener here. Default `true` — the hub's anchor is built with `isOracleDnsListeningEndpointEnabled = false`. Set `false` only for a hub whose anchor already has that flag on. |
| `hub_listening_endpoint_name` | string | — | Name of the listening endpoint. Default `"dnsHubListener"`. Unique within the hub resolver; renaming **replaces** the endpoint. |
| `hub_listening_endpoint_ip` | string | — | When the endpoint is created here: **pins** its address inside `hub_resolver_subnet_cidr` (OCI picks a free one when `null`). Worth pinning — spokes and Azure hold this IP literally. When `create_hub_listening_endpoint = false`: overrides discovery from the hub resolver. |
| `hub_resolver_security_list_id` | string | — | **Default security list** on the hub resolver subnet. DNS 53 ingress is written into it, broadly. **Authoritative** — see [§8](#8-security-list-rules). `null` leaves the port-53 rules to you. |
| `allow_all_egress` | bool | — | Re-state the `all → 0.0.0.0/0` egress rule a default list normally ships with, on every list managed here. Default `true`. Turn off only for lists you know carry no such rule. |
| `hub_lpg_limit` | number | — | Max LPGs on the hub VCN. Default `10`. Exceeding it **warns** at plan time; it does not block. Raise to match a service-request increase. |
| `azure_forward_domains` | list(string) | — | Domains every environment resolves via the hub. Default `["azure.com", "windows.net"]`. |
| `hub_resolver_forward_rules` | map(object) | — | Extra FORWARD rules on the **hub's own** resolver. Default `{}`, which leaves that resolver's rules unmanaged. See [7.4](#74-extra-forward-rules-on-the-hub-resolver) before setting it. |
| `preserve_unmanaged_hub_resolver_rules` | bool | — | Carry the resolver's existing rules — the anchor's — through when the rule list becomes managed. Default `true`. **Leave it on.** |
| `environments` | map(object) | ✅ | One entry per VM cluster VCN — see [7.2](#72-environments). |

### 7.2 `environments`

Map of VM cluster VCNs to wire to the hub. The **key** is a short label (`prod`, `nonprod`) used in
resource names.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `vcn_id` | string | — (required) | OCID of this environment's VM cluster VCN. |
| `resolver_subnet_id` | string | — (required) | Subnet that will host this VCN's forwarding endpoint. |
| `resolver_subnet_cidr` | string | — (required) | CIDR of that subnet. |
| `resolver_security_list_id` | string | `null` | **Default security list** on that resolver subnet. The DNS rules are written into it, replacing whatever else it holds. `null` leaves them to you. |
| `view_ids` | list(string) | — (required) | OCIDs of the **existing** private views for this VCN. Attached to the hub resolver, never created. A list because one VCN may carry several views; duplicates across environments are deduplicated before attachment. |
| `existing_hub_lpg_id` | string | `null` | Hub-side LPG of a peering that **already joins this VCN to the hub**. When set, no LPG pair is created — see [7.3](#73-when-the-vcns-are-already-peered). |
| `existing_exadata_lpg_id` | string | `null` | This VCN's side of that existing peering. Must be set together with `existing_hub_lpg_id`; a variable validation rejects one without the other. |

### 7.3 When the VCNs are already peered

**OCI permits exactly one peering between any two VCNs.** If a VM cluster VCN is already joined to
the hub — by another stack, by the platform, or by hand — creating a second pair fails:

```
Error: ... Message: A peering with VCN ocid1.vcn.oc1.iad.... has already been established.
Operation Name: ConnectLocalPeeringGateways
```

That failure is worse than it looks. `CreateLocalPeeringGateway` **succeeds** and only the `connect`
call fails, so each attempt leaves **two orphaned gateways** behind — created, unpeered, and counting
against the 10-LPG limit on both VCNs. Retrying strands two more, and the hub exhausts its budget
first since it accumulates one per environment.

Point the environment at the existing pair instead, and no gateways are created:

```hcl
environments = {
  prod = {
    # ...
    existing_hub_lpg_id     = "ocid1.localpeeringgateway.oc1.iad...."  # hub side
    existing_exadata_lpg_id = "ocid1.localpeeringgateway.oc1.iad...."  # this VCN's side
  }
  Demo = {
    # ... omit both — the pair is created as normal
  }
}
```

Finding the OCIDs — search the **whole tenancy**, since an LPG may live in a different compartment
from its VCN and a compartment-scoped list will miss it:

```bash
oci search resource structured-search \
  --query-text "query localpeeringgateway resources" \
  --query 'data.items[].{name:"display-name",id:identifier,comp:"compartment-id"}' --output table

oci network local-peering-gateway get --local-peering-gateway-id <id> \
  --query 'data.{name:"display-name",vcn:"vcn-id",status:"peering-status",peer:"peer-id"}'
```

Take the pair whose `peering-status` is `PEERED` and whose `vcn-id`s are the hub and that spoke.

Referenced pairs are **not managed**: Terraform neither reads their status nor deletes them on
destroy. `peering_status` reports `"EXISTING (unmanaged)"` for them, and `lpg_managed` is `false` —
verify such a peering yourself. The route rules in [§9](#9-routing--manual-by-design) are still
required, and still use these OCIDs as targets.

### 7.4 Extra FORWARD rules on the hub resolver

`hub_resolver_forward_rules` puts additional rules on the **hub's own** resolver — for a domain the
hub must send somewhere that is not Azure, such as an on-prem or partner DNS server:

```hcl
hub_resolver_forward_rules = {
  onprem = {
    source_endpoint_name   = "anchorForwardingEndpoint"  # a FORWARDING endpoint on the hub resolver
    destination_addresses  = ["192.168.10.53", "192.168.11.53"]
    qname_cover_conditions = ["corp.example.com"]
  }
}
```

This is **not** where the per-spoke rules live. Each VM cluster VCN's `FORWARD` rule sits on its own
resolver and comes from `azure_forward_domains` — see [§2](#2-architecture).

> **⚠ Declaring one rule makes Terraform authoritative over the entire list.** The OCI API replaces
> a resolver's rules wholesale, and **the hub resolver is shared with the Network Anchor**, whose
> control plane writes the OCI→Azure forwarding rules to it. A naive `rules` block would delete them.
>
> `preserve_unmanaged_hub_resolver_rules` (default `true`) is what prevents that: the live rules are
> read at plan time, matched against the ones declared here so this configuration's own entries are
> not doubled, and re-sent alongside them. **Leave it on.** Setting it `false` deletes every rule on
> the resolver that is not in the map above.

**Before the first apply that declares a rule**, look at what is being carried through:

```bash
terraform plan
terraform output hub_resolver_rules_preserved   # the anchor's rules, as read from the resolver
terraform output hub_resolver_rules             # preserved + declared: what will be sent
```

Three behaviours worth knowing:

| | |
|---|---|
| **Empty map** | No `rules` block is emitted at all and the resolver's rules are untouched. This is the default and the safe state. |
| **Removing a rule from the map** | Does **not** remove it from the resolver. It stops matching as one of ours and is preserved as a foreign rule instead — nothing here deletes a rule it did not just write. Delete it in the console or with `oci dns resolver update`. |
| **`source_endpoint_name`** | Must name a **forwarding** endpoint that already exists on the hub resolver — the anchor's, from `isOracleDnsForwardingEndpointEnabled`, not the listener this blueprint creates. A name that matches nothing makes OCI reject the whole update, taking the view attachments in the same call with it, so a `check` block warns at plan time and lists the forwarding endpoints it did find. |

---

## 8. Security list rules

This blueprint writes the DNS rules into the **default security list** you name for each resolver
subnet — `hub_resolver_security_list_id`, and each environment's `resolver_security_list_id`. Those
lists are already attached to their subnets, so there is nothing to attach afterwards.

### What gets written

| List | Direction | Peer | Port |
|---|---|---|---|
| Hub resolver | ingress | `0.0.0.0/0` | UDP + TCP 53 |
| Each spoke | egress | `0.0.0.0/0` | UDP + TCP 53 |
| Each spoke | ingress | `0.0.0.0/0` | UDP + TCP 53 |
| All, while `allow_all_egress` | egress | `0.0.0.0/0` | all protocols |

Rules are **stateful**, so replies need no counterpart rule. The spoke **egress** is the one that
carries real traffic — the forwarding endpoint is what initiates, sending the Azure domains up to
the hub listener.

**Why `0.0.0.0/0` rather than the specific CIDRs.** Same posture as the Network Anchor's own NSG.
Everything that legitimately queries these listeners is a resolver — each spoke's forwarding
endpoint over its LPG, and Azure's private resolver. Enumerating those CIDRs bought a list to keep
in step with every new spoke and every Azure-side change, and a silent outage whenever it fell
behind. Reaching a resolver endpoint still requires a route and a peering; the rule alone grants
nothing.

### ⚠ The rule set is authoritative

The OCI API replaces a security list's rules wholesale. **What this blueprint declares becomes the
whole list** — anything on it today that is not in the table above is removed on apply. Inspect each
one first:

```bash
# which lists govern the subnet
oci network subnet get --subnet-id <resolver-subnet-ocid>   --query 'data."security-list-ids"'

# what a list currently holds
oci network security-list get --security-list-id <seclist-ocid>   --query 'data.{ingress:"ingress-security-rules",egress:"egress-security-rules"}'
```

`allow_all_egress` (default `true`) re-states the `all → 0.0.0.0/0` egress rule a default list
normally ships with, so leaving it on preserves that much. Anything else — SSH ingress, ICMP
path-MTU rules — is **not** preserved. If a list carries rules you need, either leave its OCID out
of the configuration and write the DNS rules yourself, or point the blueprint at a list that does
not carry them.

Omitting an OCID skips that subnet entirely: no security list resource, no rules.

---

## 9. Routing — manual, by design

**Terraform does not manage route tables here.** It creates the LPG pair, the Exadata forwarding
endpoint, the forwarding rules and the Exadata-side DNS rules; the two route rules that carry DNS
traffic over the LPGs are added by hand, once, after `apply`.

This is deliberate. Managing them would mean `oci_core_default_route_table` with
`manage_default_resource_id`, which makes Terraform **authoritative** over the whole table — every
rule not in the config is deleted on the next apply. On an Exadata VCN those rules belong to Oracle,
are not reliably enumerable, and can be added *after* you import, so a later apply would silently
remove live routes. An earlier version offered this behind a `manage_route_tables` flag; it was
removed.

### 9.1 The two rules

One per side, mirroring each other. Both point at the LPG on their own side and target the peer's
resolver subnet:

| Add to | Destination | Target |
|--------|-------------|--------|
| **VM cluster** VCN route table (the one the resolver subnet uses) | Hub resolver subnet CIDR | Spoke-side LPG |
| **Hub** VCN route table (the one the hub resolver subnet uses) | That VCN's resolver subnet CIDR | Hub-side LPG |

If the resolver subnets use dedicated route tables you own, add the rules there. If they use the VCN
default route table, add them there — either way, **add rather than replace**, so existing routes
survive.

### 9.2 Getting the values

The LPG OCIDs are outputs:

```bash
terraform output -json links | jq -r 'to_entries[] |
  "\(.key): exadata_lpg=\(.value.exadata_lpg_id) hub_lpg=\(.value.hub_lpg_id)"'
```

The CIDRs are the ones you supplied: `hub_resolver_subnet_cidr` and each environment's
`resolver_subnet_cidr` in `terraform.tfvars`.

### 9.3 Adding them

Console: **Networking → VCN → Route Tables → the resolver subnet's table → Add Route Rules**,
target type *Local Peering Gateway*.

CLI — read the existing rules first and append, since `--route-rules` **replaces** the whole list:

```bash
# 1. Current rules, so nothing is lost
oci network route-table get --rt-id <spoke-rt-ocid> --query 'data."route-rules"' > spoke-rules.json

# 2. Append the DNS rule, then apply the combined list
oci network route-table update --rt-id <spoke-rt-ocid> --route-rules file://spoke-rules-with-dns.json

# 3. Same on the hub side, with the peer CIDR and the hub LPG
```

A rule looks like:

```json
{
  "destination": "<peer resolver subnet CIDR>",
  "destinationType": "CIDR_BLOCK",
  "networkEntityId": "<LPG OCID on this side>",
  "description": "DNS to peer resolver subnet via LPG"
}
```

### 9.4 Checking it worked

```bash
terraform output -json links | jq -r '.[].peering_status'   # expect PEERED
```

`PEERED` only means the LPGs are connected — it does not confirm the routes exist. Resolve a
database FQDN from an Azure host, or a private Azure name from a database node, to confirm traffic
actually flows.

---

## 10. Outputs

| Output | Shape | Notes |
|--------|-------|-------|
| `hub_listening_endpoint_ip` | string | The hub listener's IP. **Point Azure's DNS forwarding ruleset here.** Every spoke's `FORWARD` rule already targets it. |
| `hub_listening_endpoint_name` | string | Name of the listening endpoint created here — `null` when the anchor's own endpoint is being consumed instead. |
| `attached_views` | list(string) | Flat, deduplicated list of every view attached to the hub resolver. |
| `attached_views_by_environment` | map(list(string)) | The same OCIDs grouped per environment, as configured. |
| `hub_resolver_rules` | list(object) | The full rule list sent to the hub resolver: preserved rules first, then those declared in `hub_resolver_forward_rules`. Empty when that map is empty. |
| `hub_resolver_rules_preserved` | list(object) | Rules read from the live resolver and carried through — what would have been deleted without `preserve_unmanaged_hub_resolver_rules`. **Check this before the first apply that declares a rule.** |
| `links` | map keyed by env | `exadata_lpg_id`, `hub_lpg_id`, `lpg_managed`, `forwarding_endpoint_ip`, `forwarding_endpoint_name`, `peering_status` |

`lpg_managed` is `false` where the pair was referenced rather than created ([§7.3](#73-when-the-vcns-are-already-peered)); `peering_status` then reads `"EXISTING (unmanaged)"` instead of `PEERED`.

```bash
terraform output hub_listening_endpoint_ip
terraform output -json links | jq '.prod.peering_status'
```

---

## 11. Adding another VM cluster VCN

Add a key to the `environments` map in `terraform.tfvars`. Each entry is **one VM cluster VCN**, and
gets its own LPG pair to the hub, forwarding endpoint, FORWARD rule and DNS rules. Its `view_ids`
are attached to the hub resolver.

Two things this handles that are easy to get wrong:

- **Several VCNs sharing a view.** Two VM cluster VCNs provisioned against the same private view
  list the same OCID in their `view_ids`. The attachment list is deduplicated, so the view is
  attached once — a duplicate would be rejected.
- **One VCN with several views.** `view_ids` is a list, so a VCN carrying split zones per
  application attaches all of them.

You still add the **two route rules by hand for each new VCN** ([§9](#9-routing--manual-by-design)).

Both limits from the top of this README bite here:

- **Region.** The new VCN must be in the same region as the hub — LPG peering does not cross
  regions. A VCN elsewhere needs its own hub.
- **LPG count.** The new VCN consumes one more LPG on the hub. Past `hub_lpg_limit` (default 10)
  `terraform plan` emits a warning naming the count and the limit; the apply still runs. Raise the
  limit by service request and update `hub_lpg_limit`, or move the VCN to a second hub.

---

## 12. Destroying

```bash
terraform destroy
```

Destroy here is **not symmetric with apply**, because two of the resources manage objects this
configuration never created. Read this before running it against a shared hub.

### What is actually deleted

| Resource | On destroy |
|----------|------------|
| LPG pair (both sides) | **Deleted.** Peering torn down; DNS stops crossing between the VCNs. |
| Forwarding endpoint on each VM cluster VCN | **Deleted.** (Provider default timeout: 20 min.) |
| Hub **listening** endpoint | **Deleted** — it is created here. Azure stops resolving through this hub, and every spoke's forward rule loses its destination. Recreating it draws a new address unless `hub_listening_endpoint_ip` pins one. |
| Security list rules | **Cleared** from the lists you named. The lists themselves survive — they are default lists, adopted not created, and OCI does not delete a VCN's default list — but the DNS rules and the `allow_all_egress` rule go with the destroy, leaving those lists empty. |

### What survives — but is modified

`oci_dns_resolver` is an *update-only* resource: it manages a resolver that belongs to the VCN and
cannot be created or deleted independently. The provider documents the destroy behaviour as:

> “This resource does not delete the underlying DNS Resolver. The resolver itself is deleted only
> when the attached VCN is deleted. When this Terraform resource is destroyed, managed properties
> on the resolver (for example, attached views and rules) **are cleared**.”

So the resolvers stay, but:

| Resolver | On destroy |
|----------|------------|
| Hub resolver (`oci_dns_resolver.hub`) | View attachments **cleared** — Azure stops resolving database hostnames. |
| Each VM cluster VCN resolver (`oci_dns_resolver.exadata`) | The FORWARD rule **cleared** — databases stop resolving Azure FQDNs. |

> **⚠ The hub resolver is shared with the Network Anchor.** "Managed properties … are cleared"
> applies to the resolver's **rules** as well as its attached views — and the Network Control Plane
> writes forwarding rules to that same resolver when inbound DNS is enabled on the anchor. A
> `terraform destroy` here can therefore clear **anchor-managed rules you never put in this
> configuration**, breaking OCI→Azure resolution for everything using that anchor, not just the
> environments defined here.
>
> Before destroying against a shared hub: record the resolver's current rules
> (`oci dns resolver get --resolver-id <ocid>`), and be ready to have the anchor re-apply them.
> Prefer removing a **single environment** (delete its key from `environments` and apply) over
> destroying the whole configuration.

### What is never touched

- **Private views and zones** — not managed here; the database records in them survive.
- **The anchor's forwarding endpoint** and its forwarding rules — created by the Network Anchor.
- **The anchor's own NSG and delegated subnet.**
- **The manual route rules** from [§9](#9-routing--manual-by-design) — Terraform never managed them,
  so they persist as dangling routes pointing at deleted LPGs. **Remove them by hand.**
- **The VCNs, subnets and NSGs themselves**, and every security list whose OCID was not given to this configuration.

### Removing one environment instead

Safer, and the common case — it leaves the hub resolver's other attachments and the anchor's rules
alone:

```bash
# delete that key from the environments map in terraform.tfvars, then
terraform plan     # confirm only that environment's LPGs/endpoint/rules are removed
terraform apply
```

Then delete that VCN's two manual route rules.

---

## 13. Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| Plan fails on `hub_resolver_subnet_id is required…` | The listening endpoint is created here and needs a subnet in the hub VCN. Set `hub_resolver_subnet_id`, or set `create_hub_listening_endpoint = false` if the anchor already provides the listener. |
| `hub_listening_endpoint_ip` is `null` | Only possible with `create_hub_listening_endpoint = false`: the anchor's listening endpoint does not exist, or discovery matched nothing. Confirm that anchor was created with `isOracleDnsListeningEndpointEnabled`, set `hub_listening_endpoint_ip` explicitly — or flip the flag back and let this blueprint create the listener. |
| Two listeners on the hub resolver | The hub's anchor was created with `isOracleDnsListeningEndpointEnabled` **on**. Only one is wired to the spokes. Rebuild the anchor with the flag off, or keep the platform's and set `create_hub_listening_endpoint = false`. |
| Azure cannot resolve database hostnames | The environment's `view_ids` are wrong or not attached — check `terraform output attached_views`. If the zone is *empty*, the cluster was not provisioned against that view (see [§3](#3-prerequisites)); the view must pre-date the cluster. |
| Databases cannot resolve Azure FQDNs | Check, in order: the FORWARD rule exists on that VCN's resolver, the manual route rules are on **both** tables ([§9](#9-routing--manual-by-design)), the DNS rules are on the resolver subnets' security lists ([§8](#8-security-list-rules)), and the domain is listed in `azure_forward_domains`. |
| A security list lost rules after apply | Expected and documented: the rule set is authoritative, so anything not declared here is removed ([§8](#8-security-list-rules)). Restore them by hand, then either point the blueprint at a list that carries nothing else, or omit the OCID and write the DNS rules yourself. |
| `peering_status` not `PEERED` | Re-run `apply`; confirm both VCNs are in the **same region** and the OCIDs are correct. |
| Duplicate view attachment rejected | Two environments list the same view — the config deduplicates, so this means a view was also attached outside Terraform. |
| Plan warns about `hub_lpg_limit` | Environments exceed the hub VCN's LPG limit. Raise it by service request and set `hub_lpg_limit`, or split across a second hub ([§11](#11-adding-another-vm-cluster-vcn)). |
| Views attached outside Terraform disappeared | `attached_views` is authoritative — the API replaces the whole list. Add such views to `view_ids` so they are managed here. |
| OCI→Azure resolution broke after a destroy | The hub resolver's rules were cleared, including anchor-managed ones. See [§12](#12-destroying). |
| Manual route rules point at nothing | LPGs were destroyed but the routes were not. Remove them by hand. |

Validate before applying:

```bash
terraform fmt -recursive
terraform validate
```
