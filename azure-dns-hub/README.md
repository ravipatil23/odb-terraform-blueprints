# Database@Azure — Custom DNS, Scenario #2 (Network Anchor as DNS Hub)

Terraform that wires one or more **Exadata VCNs** to a central **DNS Hub VCN**
(the Network Anchor), implementing Scenario #2 from the A-Team article
*“Custom DNS for Oracle AI Database@Azure”* and the Oracle docs
*“DNS for Oracle AI Database@Azure”*.

## What it does

For each Exadata environment (e.g. `prod`, `nonprod`) this creates the wiring
between that environment's Exadata VCN and the shared DNS Hub VCN:

| # | Resource | Purpose |
|---|----------|---------|
| 1 | `oci_core_local_peering_gateway` ×2 | 1:1 LPG pair (Exadata VCN ⇄ Hub VCN). LPG peering is strictly 1:1, so **each environment gets its own pair**. |
| 2 | `oci_dns_resolver_endpoint` (forwarding) | Forwarding endpoint on the Exadata VCN resolver — egress queries from the databases. |
| 3 | `oci_dns_resolver` rule (`FORWARD`) | Sends the configured Azure domains to the Hub **listening** endpoint, so databases resolve Azure FQDNs. |
| 4 | `oci_core_network_security_group_security_rule` | Opens DNS (UDP/TCP 53) across the peering. |

The **root module** additionally owns the hub-side shared objects:
the **listening** endpoint (which Azure queries), the **forwarding** endpoint,
and one **private view + private zone** per environment.

```
Azure private resolver ─▶ Hub LISTENING endpoint ─▶ private views/zones ─▶ OCI private IPs
Database (prod/nonprod) ─▶ Exadata FORWARDING endpoint ─▶ FORWARD rule ─▶ Hub LISTENING endpoint ─▶ Azure
```

## Prerequisites (already provisioned)

- A **DNS Hub VCN** with a dedicated subnet + NSG for DNS resolver endpoints.
- One **Exadata VCN per environment**, each with a resolver subnet (+ NSG).
- The OCIDs and CIDRs of all of the above (fill into `terraform.tfvars`).

## Usage

```bash
cd terraform/azure-dns-hub
cp terraform.tfvars.example terraform.tfvars   # then edit the OCIDs
terraform init
terraform plan
terraform apply
```

After apply, point Azure's DNS forwarding ruleset at the hub listener:

```bash
terraform output hub_listening_endpoint_ip
```

## Routing — manual, by design

**Terraform does not manage route tables here.** It creates the LPG pair, the
resolver endpoints, the forwarding rules and the NSG rules; the two route rules
that carry DNS traffic over the LPGs are added by hand, once, after `apply`.

This is deliberate. Managing them would mean `oci_core_default_route_table` with
`manage_default_resource_id`, which makes Terraform **authoritative** over the
whole table — every rule not in the config is deleted on the next apply. On an
Exadata VCN those rules belong to Oracle, are not reliably enumerable, and can be
added *after* you import, so a later apply would silently remove live routes. An
earlier version offered this behind a `manage_route_tables` flag; it was removed.

### The two rules

One per side, mirroring each other. Both point at the LPG on their own side and
target the peer's resolver subnet:

| Add to | Destination | Target |
|--------|-------------|--------|
| **Exadata** VCN route table (the one the resolver subnet uses) | Hub resolver subnet CIDR | Exadata-side LPG |
| **Hub** VCN route table (the one the hub resolver subnet uses) | Exadata resolver subnet CIDR | Hub-side LPG |

If the resolver subnets use dedicated route tables you own, add the rules there.
If they use the VCN default route table, add them there — either way, add rather
than replace, so existing routes survive.

### Getting the values

The LPG OCIDs are outputs:

```bash
terraform output -json links | jq -r 'to_entries[] |
  "\(.key): exadata_lpg=\(.value.exadata_lpg_id) hub_lpg=\(.value.hub_lpg_id)"'
```

The CIDRs are the ones you supplied: `hub_resolver_subnet_cidr` and each
environment's `resolver_subnet_cidr` in `terraform.tfvars`.

### Adding them

Console: **Networking → VCN → Route Tables → the resolver subnet's table → Add
Route Rules**, target type *Local Peering Gateway*.

CLI — read the existing rules first and append, since `--route-rules` **replaces**
the whole list:

```bash
# 1. Current rules, so nothing is lost
oci network route-table get --rt-id <exadata-rt-ocid>   --query 'data."route-rules"' > exadata-rules.json

# 2. Append the DNS rule, then apply the combined list
oci network route-table update --rt-id <exadata-rt-ocid>   --route-rules file://exadata-rules-with-dns.json

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

### Checking it worked

```bash
terraform output -json links | jq -r '.[].peering_status'   # expect PEERED
```

`PEERED` only means the LPGs are connected — it does not confirm the routes
exist. Resolve a database FQDN from an Azure host, or a private Azure name from a
database node, to confirm traffic actually flows.

## Adding another environment

Add a key to the `environments` map in `terraform.tfvars` — a new LPG pair,
forwarding endpoint, rule, NSG rules and private zone are created for it.
```
