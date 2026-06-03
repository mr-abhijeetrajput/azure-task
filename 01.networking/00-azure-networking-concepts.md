# Azure Networking Concepts — Complete Reference

> This document covers every networking primitive you'll use across Tasks 01–10.
> Read this before working with subnets, NSGs, or route tables.

---

## Table of Contents

1. [Public Subnet vs Private Subnet](#1-public-subnet-vs-private-subnet)
2. [NSG — Network Security Group](#2-nsg--network-security-group)
3. [ASG — Application Security Group](#3-asg--application-security-group)
4. [NAT Gateway](#4-nat-gateway)
5. [Subnet Delegation](#5-subnet-delegation)
6. [Private Endpoint](#6-private-endpoint)
7. [Service Endpoint](#7-service-endpoint)
8. [Route Table (UDR)](#8-route-table-udr)
9. [Giving Internet Access to a Private Subnet](#9-giving-internet-access-to-a-private-subnet)
10. [Concept Comparison — When to Use What](#10-concept-comparison--when-to-use-what)

---

## 1. Public Subnet vs Private Subnet

Azure doesn't have an explicit "public/private" toggle on subnets the way AWS does.
Instead, **a subnet's public or private nature is determined by how traffic flows in and out**.

```
PUBLIC SUBNET                          PRIVATE SUBNET
──────────────────────────────────     ──────────────────────────────────
Resources CAN have Public IPs          Resources have ONLY Private IPs
Direct inbound from internet ✅        No direct inbound from internet ✅
Direct outbound to internet ✅         No direct outbound* (needs NAT/FW)
Example: AGW, Bastion, NVA            Example: VMSS, AKS nodes, DBs
```

### What makes a subnet "public" in Azure

1. Resources in it have **Public IP addresses** attached to their NIC or Load Balancer
2. NSG rules allow inbound traffic from `0.0.0.0/0` (internet)
3. The default system route `0.0.0.0/0 → Internet` is active (no UDR override)

### What makes a subnet "private" in Azure

1. Resources have **no Public IP** — only private IPs from the VNet range
2. NSG blocks all inbound from internet
3. A UDR redirects `0.0.0.0/0` to a firewall/NVA instead of directly to internet
4. Outbound internet access is provided via NAT Gateway or Azure Firewall (not directly)

### In this lab

| Subnet | Nature | Why |
|--------|--------|-----|
| `subnet-agw` (10.10.1.0/24) | **Public** | AGW has a public IP; needs direct internet for its frontend |
| `subnet-backend` (10.10.2.0/24) | **Private** | VMSS/AKS nodes have no public IPs; UDR forces egress via firewall |
| `subnet-postgres` (10.10.4.0/24) | **Private** | PostgreSQL has no public endpoint; accessed only from within VNet |
| `subnet-aks` (10.10.5.0/24) | **Private** | AKS nodes have no public IPs |
| `subnet-apim` (10.10.6.0/24) | **Private** | APIM in External mode; private IP inside VNet |

> **Key insight:** In Azure, a subnet becomes private by *withholding* public IPs from its
> resources and *overriding* the default internet route. There is no checkbox — it's a
> combination of IP assignment policy + NSG rules + UDR.

---

## 2. NSG — Network Security Group

An NSG is a **stateful firewall** for Layer 4 (TCP/UDP/ICMP) that filters traffic by:
- Source IP / destination IP (or CIDR range)
- Source port / destination port
- Protocol (TCP, UDP, Any)

NSGs can be attached to:
- A **subnet** — rules apply to ALL resources in that subnet
- A **NIC** — rules apply only to that specific VM/resource

When both are attached, **both NSGs are evaluated** — subnet NSG first for inbound, NIC NSG first for outbound.

### Rules anatomy

Every NSG rule has:

| Field | What it controls | Example |
|-------|-----------------|---------|
| Priority | Lower number = evaluated first (100–4096) | `100` |
| Name | Human label | `allow-http` |
| Source | Where traffic is coming from | `Internet`, `10.10.1.0/24`, `*` |
| Source Port | Port on the sender | `*` (usually any) |
| Destination | Where traffic is going | `10.10.2.0/24`, `VirtualNetwork` |
| Destination Port | Port on the receiver | `80`, `443`, `22` |
| Protocol | TCP / UDP / ICMP / Any | `TCP` |
| Action | Allow or Deny | `Allow` |

### Default rules Azure adds automatically (you cannot delete these)

**Inbound defaults:**

| Priority | Name | Source | Destination | Port | Action |
|----------|------|--------|-------------|------|--------|
| 65000 | AllowVnetInBound | VirtualNetwork | VirtualNetwork | Any | **Allow** |
| 65001 | AllowAzureLoadBalancerInBound | AzureLoadBalancer | Any | Any | **Allow** |
| 65500 | DenyAllInBound | Any | Any | Any | **Deny** |

**Outbound defaults:**

| Priority | Name | Source | Destination | Port | Action |
|----------|------|--------|-------------|------|--------|
| 65000 | AllowVnetOutBound | VirtualNetwork | VirtualNetwork | Any | **Allow** |
| 65001 | AllowInternetOutBound | Any | Internet | Any | **Allow** |
| 65500 | DenyAllOutBound | Any | Any | Any | **Deny** |

> The default `DenyAllInBound` at 65500 means: **if no rule matches, traffic is dropped**.
> Your custom rules (priority < 65000) add exceptions to this default-deny posture.

### Common NSG for subnet-backend (VMSS / AKS)

```bash
# Create NSG
az network nsg create \
  --resource-group $RESOURCE_GROUP \
  --name nsg-backend \
  --location $LOCATION

# Allow AGW to reach backend on HTTP (AGW sends health probes and traffic)
az network nsg rule create \
  --resource-group $RESOURCE_GROUP \
  --nsg-name nsg-backend \
  --name allow-agw-to-backend \
  --priority 100 \
  --source-address-prefixes 10.10.1.0/24 \
  --destination-port-ranges 80 \
  --protocol TCP \
  --access Allow \
  --direction Inbound

# Allow HTTPS from internet (if backend serves HTTPS directly — uncommon)
az network nsg rule create \
  --resource-group $RESOURCE_GROUP \
  --nsg-name nsg-backend \
  --name allow-https-inbound \
  --priority 110 \
  --source-address-prefixes Internet \
  --destination-port-ranges 443 \
  --protocol TCP \
  --access Allow \
  --direction Inbound

# Deny everything else inbound (already covered by default 65500, but explicit is clearer)
az network nsg rule create \
  --resource-group $RESOURCE_GROUP \
  --nsg-name nsg-backend \
  --name deny-all-inbound \
  --priority 4000 \
  --source-address-prefixes '*' \
  --destination-port-ranges '*' \
  --protocol '*' \
  --access Deny \
  --direction Inbound

# Attach NSG to subnet
az network vnet subnet update \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name subnet-backend \
  --network-security-group nsg-backend
```

### Common NSG for subnet-agw (Application Gateway)

```bash
az network nsg create \
  --resource-group $RESOURCE_GROUP \
  --name nsg-agw \
  --location $LOCATION

# REQUIRED: Allow AGW V2 infrastructure communication (65200–65535)
# Azure AGW needs this range for internal health and management — without it, AGW breaks
az network nsg rule create \
  --resource-group $RESOURCE_GROUP \
  --nsg-name nsg-agw \
  --name allow-agw-infra \
  --priority 100 \
  --source-address-prefixes GatewayManager \
  --destination-address-prefixes '*' \
  --destination-port-ranges 65200-65535 \
  --protocol TCP \
  --access Allow \
  --direction Inbound

# Allow inbound HTTP from internet to AGW
az network nsg rule create \
  --resource-group $RESOURCE_GROUP \
  --nsg-name nsg-agw \
  --name allow-http-inbound \
  --priority 110 \
  --source-address-prefixes Internet \
  --destination-port-ranges 80 \
  --protocol TCP \
  --access Allow \
  --direction Inbound

# Allow inbound HTTPS from internet to AGW
az network nsg rule create \
  --resource-group $RESOURCE_GROUP \
  --nsg-name nsg-agw \
  --name allow-https-inbound \
  --priority 120 \
  --source-address-prefixes Internet \
  --destination-port-ranges 443 \
  --protocol TCP \
  --access Allow \
  --direction Inbound

az network vnet subnet update \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name subnet-agw \
  --network-security-group nsg-agw
```

### NSG service tags — use these instead of IP ranges

Azure maintains named groups of IPs called **service tags**. Use them in NSG rules so you don't need to hardcode Azure's IP ranges (which change constantly):

| Tag | What it represents |
|-----|-------------------|
| `Internet` | All public IPs (anything outside VNet) |
| `VirtualNetwork` | All addresses in current VNet + peered VNets |
| `AzureLoadBalancer` | Azure's health probe IP (`168.63.129.16`) |
| `GatewayManager` | Azure AGW management plane |
| `AzureCloud` | All Azure datacenter IPs |
| `Storage` | Azure Storage IPs in the region |
| `Sql` | Azure SQL IPs in the region |
| `AzureMonitor` | Azure Monitor/Log Analytics IPs |
| `AppService` | Azure App Service outbound IPs |

---

## 3. ASG — Application Security Group

An ASG is a **logical grouping of NICs** (VMs/VMSS instances) that you can use as source or destination in NSG rules instead of IP addresses.

### The problem ASGs solve

Without ASG, NSG rules reference IPs:
```
Allow 10.10.2.4, 10.10.2.5, 10.10.2.6 (web servers) → port 80 from 10.10.1.0/24
```
When VMs scale out, you must update the NSG rule manually every time a new IP appears.

With ASG, NSG rules reference groups:
```
Allow asg-webservers → port 80 from asg-agw
```
When VMs scale out, you just add their NIC to the ASG — NSG rules update automatically.

### How to use ASGs

```bash
# Create ASGs
az network asg create \
  --resource-group $RESOURCE_GROUP \
  --name asg-webservers \
  --location $LOCATION

az network asg create \
  --resource-group $RESOURCE_GROUP \
  --name asg-appservers \
  --location $LOCATION

# Create NSG rule referencing ASGs (not IPs)
az network nsg rule create \
  --resource-group $RESOURCE_GROUP \
  --nsg-name nsg-backend \
  --name allow-web-to-app \
  --priority 200 \
  --source-asgs asg-webservers \
  --destination-asgs asg-appservers \
  --destination-port-ranges 8080 \
  --protocol TCP \
  --access Allow \
  --direction Inbound

# Assign a VM's NIC to an ASG
az network nic update \
  --resource-group $RESOURCE_GROUP \
  --name <nic-name> \
  --application-security-groups asg-webservers
```

### ASG constraints

- ASG and the NICs assigned to it must be in the **same region**
- You can assign a NIC to **multiple ASGs**
- ASGs don't work across VNet peerings (only within a single VNet)
- ASGs are most useful for VMSS (many instances, IPs change constantly)

---

## 4. NAT Gateway

A NAT Gateway provides **outbound internet access for private subnets** without exposing resources to inbound traffic.

### How it works

```
Without NAT Gateway (default system route):
  Private VM (10.10.2.5)
       │
       │ Outbound to 8.8.8.8
       │ Source IP: 10.10.2.5 (private — internet rejects this)
       ▼
  ✗ DROPPED by internet (private IP not routable)

With NAT Gateway:
  Private VM (10.10.2.5)
       │
       │ Outbound to 8.8.8.8
       ▼
  NAT Gateway (Public IP: 20.x.x.x)
       │
       │ Source IP translated to 20.x.x.x (SNAT)
       ▼
  ✅ Internet receives request, replies to 20.x.x.x, NAT Gateway forwards back
```

### When to use NAT Gateway vs Azure Firewall

| | NAT Gateway | Azure Firewall |
|-|-------------|----------------|
| Purpose | Outbound SNAT only | Outbound + inbound filtering, FQDN rules, logging |
| Cost | ~₹3/hr | ~₹65/hr |
| FQDN filtering | ❌ No | ✅ Yes |
| Outbound logs | ❌ No | ✅ Yes |
| Inbound DNAT | ❌ No | ✅ Yes |
| Use when | Simple internet egress needed | Security inspection required |

### Create and attach a NAT Gateway

```bash
# Create a public IP for NAT Gateway
az network public-ip create \
  --resource-group $RESOURCE_GROUP \
  --name pip-natgw \
  --location $LOCATION \
  --sku Standard \
  --allocation-method Static

# Create NAT Gateway
az network nat gateway create \
  --resource-group $RESOURCE_GROUP \
  --name natgw-backend \
  --location $LOCATION \
  --public-ip-addresses pip-natgw \
  --idle-timeout 10

# Attach to subnet
az network vnet subnet update \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name subnet-backend \
  --nat-gateway natgw-backend
```

> **NAT Gateway takes priority over UDR for outbound traffic.**
> If both are attached to a subnet, NAT Gateway handles outbound SNAT
> UNLESS you have a UDR pointing `0.0.0.0/0` to `VirtualAppliance` — in that case
> the UDR wins and traffic goes to the firewall, NOT the NAT Gateway.

---

## 5. Subnet Delegation

Subnet delegation lets an **Azure PaaS service take ownership** of a subnet to deploy its managed infrastructure there. When you delegate a subnet, only that service can deploy resources into it.

### Why it exists

Some PaaS services (PostgreSQL Flexible Server, Azure Container Instances, API Management) need to inject their managed VMs/agents into your VNet. Delegation is the formal mechanism that:
- Gives the service permission to create NICs/resources in the subnet
- Prevents other services from accidentally deploying there
- Lets the service add its own NSG/route requirements

### Services that require subnet delegation

| Service | Delegation Name | Use Case |
|---------|----------------|----------|
| PostgreSQL Flexible Server | `Microsoft.DBforPostgreSQL/flexibleServers` | Managed Postgres with VNet injection |
| MySQL Flexible Server | `Microsoft.DBforMySQL/flexibleServers` | Managed MySQL with VNet injection |
| Azure Container Instances | `Microsoft.ContainerInstance/containerGroups` | ACI groups inside VNet |
| Azure NetApp Files | `Microsoft.Netapp/volumes` | NFS volumes |
| Azure Databricks | `Microsoft.Databricks/workspaces` | Spark clusters in VNet |
| Azure API Management | `Microsoft.ApiManagement/service` | APIM VNet injection (stv2) |
| Azure Web Apps (Regional VNet Integration) | `Microsoft.Web/serverFarms` | App Service outbound via VNet |
| Azure Kubernetes Service (kubelet) | `Microsoft.ContainerService/managedClusters` | AKS node subnet (optional) |

### How to delegate

```bash
# Delegate during subnet creation
az network vnet subnet create \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name subnet-postgres \
  --address-prefixes 10.10.4.0/24 \
  --delegations Microsoft.DBforPostgreSQL/flexibleServers

# Or add delegation to an existing subnet
az network vnet subnet update \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name subnet-postgres \
  --delegations Microsoft.DBforPostgreSQL/flexibleServers

# Verify
az network vnet subnet show \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name subnet-postgres \
  --query "delegations[].serviceName" \
  -o tsv
# Expected: Microsoft.DBforPostgreSQL/flexibleServers
```

### Critical rules for delegated subnets

> ⚠️ For PostgreSQL Flexible Server delegation specifically:
> - Do **NOT** attach an NSG (provisioning fails)
> - Do **NOT** attach a Route Table / UDR (provisioning fails)
> - Do **NOT** enable the "Private subnet" flag
> - The service manages its own outbound routing

---

## 6. Private Endpoint

A Private Endpoint brings a **PaaS service's data plane into your VNet** via a private IP address. Instead of accessing Azure Storage at `mystorageaccount.blob.core.windows.net` (public IP), you access it at `10.10.x.x` (private IP inside your VNet).

### How it works

```
WITHOUT Private Endpoint:
  VM in VNet (10.10.2.5)
       │
       │ DNS: mystorageaccount.blob.core.windows.net → 52.x.x.x (public IP)
       │ Traffic leaves VNet → goes over internet
       ▼
  Azure Storage (public endpoint)

WITH Private Endpoint:
  VM in VNet (10.10.2.5)
       │
       │ DNS: mystorageaccount.blob.core.windows.net → 10.10.2.20 (private IP via Private DNS Zone)
       │ Traffic stays INSIDE VNet
       ▼
  Private Endpoint NIC (10.10.2.20)
       │
       │ Azure internal network (no internet hop)
       ▼
  Azure Storage backend
```

### Create a private endpoint for Azure Storage

```bash
# Get storage account resource ID
STORAGE_ID=$(az storage account show \
  --resource-group $RESOURCE_GROUP \
  --name mystorageaccount \
  --query id -o tsv)

# Create the private endpoint (NIC) in your subnet
az network private-endpoint create \
  --resource-group $RESOURCE_GROUP \
  --name pe-storage \
  --location $LOCATION \
  --vnet-name $VNET_NAME \
  --subnet subnet-backend \
  --private-connection-resource-id $STORAGE_ID \
  --group-id blob \
  --connection-name pe-storage-conn

# Get the private IP assigned to the endpoint
az network private-endpoint show \
  --resource-group $RESOURCE_GROUP \
  --name pe-storage \
  --query "customDnsConfigs[].ipAddresses" \
  -o tsv
```

### DNS — the critical piece

Without DNS, VMs still resolve `mystorageaccount.blob.core.windows.net` to the public IP.
You must set up a **Private DNS Zone** to override the resolution:

```bash
# Create private DNS zone (must match the service's DNS zone exactly)
az network private-dns zone create \
  --resource-group $RESOURCE_GROUP \
  --name "privatelink.blob.core.windows.net"

# Link DNS zone to VNet (so VMs in VNet use it)
az network private-dns link vnet create \
  --resource-group $RESOURCE_GROUP \
  --zone-name "privatelink.blob.core.windows.net" \
  --name link-vnet-storage \
  --virtual-network $VNET_NAME \
  --registration-enabled false

# Create DNS A record pointing service FQDN to private IP
az network private-dns record-set a add-record \
  --resource-group $RESOURCE_GROUP \
  --zone-name "privatelink.blob.core.windows.net" \
  --record-set-name "mystorageaccount" \
  --ipv4-address 10.10.2.20
```

### Private DNS zones by service

| Service | Private DNS Zone |
|---------|-----------------|
| Blob Storage | `privatelink.blob.core.windows.net` |
| File Storage | `privatelink.file.core.windows.net` |
| Azure SQL | `privatelink.database.windows.net` |
| Key Vault | `privatelink.vaultcore.azure.net` |
| ACR | `privatelink.azurecr.io` |
| Event Hub | `privatelink.servicebus.windows.net` |
| Cosmos DB (SQL) | `privatelink.documents.azure.com` |
| PostgreSQL | `privatelink.postgres.database.azure.com` |
| AKS API Server | `privatelink.<region>.azmk8s.io` |

### Private Endpoint vs Service Endpoint

| | Private Endpoint | Service Endpoint |
|-|-----------------|-----------------|
| Traffic path | Stays in VNet (private IP) | Goes to service's public IP but via Azure backbone |
| Accessible from on-prem (VPN/ER) | ✅ Yes | ❌ No |
| Cost | ~₹0.65/hr per endpoint | Free |
| DNS change needed | ✅ Yes | ❌ No |
| Works with NSG | ✅ Yes | ✅ Yes |
| Security level | Highest — service gets a NIC in your VNet | Good — traffic stays on Azure backbone |

---

## 7. Service Endpoint

A Service Endpoint lets traffic from your subnet to a PaaS service travel over the **Azure backbone network** instead of the public internet — but the destination is still a public IP on the service's side.

### How it works

```
WITHOUT Service Endpoint:
  VM (10.10.2.5) → 8.8.8.8 path → Storage public IP (52.x.x.x)

WITH Service Endpoint:
  VM (10.10.2.5) → Azure backbone → Storage public IP (52.x.x.x)
  (traffic never leaves Azure's network, but service still sees public IP)
```

### Enable a service endpoint on a subnet

```bash
az network vnet subnet update \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name subnet-backend \
  --service-endpoints Microsoft.Storage Microsoft.KeyVault
```

### Available service endpoints

| Service | Use |
|---------|-----|
| `Microsoft.AzureActiveDirectory` | Azure AD |
| `Microsoft.AzureCosmosDB` | Cosmos DB |
| `Microsoft.CognitiveServices` | AI/ML services |
| `Microsoft.ContainerRegistry` | ACR (Docker images) |
| `Microsoft.EventHub` | Event streaming |
| `Microsoft.KeyVault` | Secrets/Certificates |
| `Microsoft.ServiceBus` | Message queue |
| `Microsoft.Sql` | Azure SQL / SQL MI |
| `Microsoft.Storage` | Blob, File, Queue |
| `Microsoft.Storage.Global` | Storage (global routing) |
| `Microsoft.Web` | App Service |

> **You can only add service endpoints for the services listed above.**
> Not all Azure services support service endpoints — for those, use Private Endpoint instead.

### Lock down a storage account to only allow access from your subnet

After enabling the service endpoint, configure the storage account's firewall:

```bash
az storage account network-rule add \
  --resource-group $RESOURCE_GROUP \
  --account-name mystorageaccount \
  --vnet-name $VNET_NAME \
  --subnet subnet-backend

# Deny all other access (only your subnet can reach it)
az storage account update \
  --resource-group $RESOURCE_GROUP \
  --name mystorageaccount \
  --default-action Deny
```

---

## 8. Route Table (UDR)

A **User Defined Route (UDR)** — implemented as a Route Table — lets you override Azure's default routing for a subnet. You tell Azure "instead of your default next hop, send this traffic to my next hop."

> Full explanation of Azure's default routing and why you need UDR is in the Foundation Setup doc (Step 6).

### Create a custom route table

```bash
az network route-table create \
  --resource-group $RESOURCE_GROUP \
  --name rt-backend \
  --location $LOCATION \
  --disable-bgp-route-propagation true
```

### Add routes to the table

```bash
# Route 1: Send all internet traffic to firewall
az network route-table route create \
  --resource-group $RESOURCE_GROUP \
  --route-table-name rt-backend \
  --name route-internet-via-fw \
  --address-prefix 0.0.0.0/0 \
  --next-hop-type VirtualAppliance \
  --next-hop-ip-address 10.10.9.4

# Route 2: Keep VNet traffic local
az network route-table route create \
  --resource-group $RESOURCE_GROUP \
  --route-table-name rt-backend \
  --name route-vnet-local \
  --address-prefix 10.10.0.0/16 \
  --next-hop-type VnetLocal

# Attach route table to subnet
az network vnet subnet update \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name subnet-backend \
  --route-table rt-backend
```

### Next hop types

| Type | When to use |
|------|------------|
| `VnetLocal` | Keep traffic inside the VNet — routes to another subnet directly |
| `Internet` | Force traffic out to internet directly (bypasses a broader UDR for specific prefix) |
| `VirtualAppliance` | Send to a specific IP — Firewall, NVA, proxy VM (requires `--next-hop-ip-address`) |
| `VirtualNetworkGateway` | Send to VPN/ExpressRoute gateway |
| `None` | Drop/blackhole — silently discard matching traffic |

### Longest-prefix match rule

Azure always picks the **most specific** matching route:

```
Traffic to 10.10.2.5   → matches 10.10.0.0/16 (more specific than 0.0.0.0/0) → VnetLocal ✅
Traffic to 8.8.8.8     → matches 0.0.0.0/0 (catch-all) → Firewall ✅
Traffic to 10.10.4.100 → matches 10.10.0.0/16 → VnetLocal ✅
```

This is why you can have both `0.0.0.0/0 → Firewall` and `10.10.0.0/16 → VnetLocal` — they don't conflict.

---

## 9. Giving Internet Access to a Private Subnet

This is the most practical section. A private subnet's VMs need internet access (to run `apt install`, pull Docker images, reach APIs) but must not be directly reachable from the internet.

### Three approaches — pick one

```
Option A: Direct Internet (lab only — no security)
Option B: NAT Gateway (simple SNAT, no inspection)
Option C: Azure Firewall (SNAT + FQDN filtering + logs) ← production
```

---

### Option A: Direct Internet via UDR (Lab only — Tasks 01–07)

Used in the lab when the firewall doesn't exist yet. Adds a temporary direct-internet route.

```
subnet-backend
      │
      │ 0.0.0.0/0 → Internet (UDR: next-hop-type Internet)
      │
      ▼
 Public Internet (direct, no inspection)
```

**Custom Route Table rules needed:**

| Route Name | Destination | Next Hop Type | Next Hop IP | Purpose |
|------------|-------------|---------------|-------------|---------|
| `route-vnet-local` | `10.10.0.0/16` | `VnetLocal` | — | VNet traffic stays local |
| `route-internet-direct-TEMP` | `0.0.0.0/0` | `Internet` | — | All other traffic → internet directly |

```bash
# Step 1: Create route table (if not already done)
az network route-table create \
  --resource-group $RESOURCE_GROUP \
  --name rt-backend \
  --location $LOCATION \
  --disable-bgp-route-propagation true

# Step 2: Add VNet-local route
az network route-table route create \
  --resource-group $RESOURCE_GROUP \
  --route-table-name rt-backend \
  --name route-vnet-local \
  --address-prefix 10.10.0.0/16 \
  --next-hop-type VnetLocal

# Step 3: Add direct internet route (TEMP)
az network route-table route create \
  --resource-group $RESOURCE_GROUP \
  --route-table-name rt-backend \
  --name route-internet-direct-TEMP \
  --address-prefix 0.0.0.0/0 \
  --next-hop-type Internet

# Step 4: Attach to subnet
az network vnet subnet update \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name subnet-backend \
  --route-table rt-backend
```

> ⚠️ Azure enforces **one route per unique prefix**. If `route-internet-via-fw` (0.0.0.0/0)
> already exists, delete it first before adding `route-internet-direct-TEMP`.

```bash
# Delete existing 0.0.0.0/0 route first (if it exists)
az network route-table route delete \
  --resource-group $RESOURCE_GROUP \
  --route-table-name rt-backend \
  --name route-internet-via-fw

# Then create the direct route
az network route-table route create \
  --resource-group $RESOURCE_GROUP \
  --route-table-name rt-backend \
  --name route-internet-direct-TEMP \
  --address-prefix 0.0.0.0/0 \
  --next-hop-type Internet
```

**Effective routes with Option A:**

```
Source    State    Prefix              NextHopType       NextHopIP
────────  ───────  ──────────────────  ────────────────  ─────────
Default   Active   10.10.0.0/16        VnetLocal
User      Active   10.10.0.0/16        VnetLocal         ← explicit VNet route wins
Default   Invalid  0.0.0.0/0           Internet          ← Azure's default, overridden
User      Active   0.0.0.0/0           Internet          ← your TEMP route (direct internet)
Default   Active   169.254.169.254/32  Internet          ← Azure system (not overridable)
Default   Active   168.63.129.16/32    Internet
```

---

### Option B: NAT Gateway (Production-ready, no inspection)

```
subnet-backend
      │
      │ 0.0.0.0/0 → Internet (system route or UDR with Internet next hop)
      │
      ▼
 NAT Gateway (translates 10.10.2.x → 20.x.x.x public IP)
      │
      ▼
 Public Internet
```

**Custom Route Table rules needed:**

| Route Name | Destination | Next Hop Type | Next Hop IP | Purpose |
|------------|-------------|---------------|-------------|---------|
| `route-vnet-local` | `10.10.0.0/16` | `VnetLocal` | — | VNet traffic stays local |
| *(No 0.0.0.0/0 rule needed)* | — | — | — | NAT Gateway intercepts automatically |

The NAT Gateway is attached to the subnet and handles SNAT automatically — you don't need a UDR pointing to it.

```bash
# Create public IP for NAT Gateway
az network public-ip create \
  --resource-group $RESOURCE_GROUP \
  --name pip-natgw \
  --location $LOCATION \
  --sku Standard \
  --allocation-method Static

# Create NAT Gateway
az network nat gateway create \
  --resource-group $RESOURCE_GROUP \
  --name natgw-backend \
  --location $LOCATION \
  --public-ip-addresses pip-natgw \
  --idle-timeout 10

# Attach NAT Gateway to subnet (replaces direct internet route)
az network vnet subnet update \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name subnet-backend \
  --nat-gateway natgw-backend

# Attach route table (only VNet-local route needed)
az network route-table create \
  --resource-group $RESOURCE_GROUP \
  --name rt-backend \
  --location $LOCATION \
  --disable-bgp-route-propagation true

az network route-table route create \
  --resource-group $RESOURCE_GROUP \
  --route-table-name rt-backend \
  --name route-vnet-local \
  --address-prefix 10.10.0.0/16 \
  --next-hop-type VnetLocal

az network vnet subnet update \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name subnet-backend \
  --route-table rt-backend
```

---

### Option C: Azure Firewall (Production — with inspection)

```
subnet-backend
      │
      │ 0.0.0.0/0 → VirtualAppliance (10.10.9.4 — Azure Firewall)
      │
      ▼
 Azure Firewall (10.10.9.4)
  - Inspects outbound traffic
  - Allows/denies by FQDN rules (e.g., allow *.ubuntu.com, deny *.malware.com)
  - Logs all connections to Log Analytics
      │
      ▼
 Public Internet
```

**Custom Route Table rules needed:**

| Route Name | Destination | Next Hop Type | Next Hop IP | Purpose |
|------------|-------------|---------------|-------------|---------|
| `route-vnet-local` | `10.10.0.0/16` | `VnetLocal` | — | VNet traffic stays local |
| `route-internet-via-fw` | `0.0.0.0/0` | `VirtualAppliance` | `10.10.9.4` | All internet traffic → Firewall |

```bash
# Create route table
az network route-table create \
  --resource-group $RESOURCE_GROUP \
  --name rt-backend \
  --location $LOCATION \
  --disable-bgp-route-propagation true

# Route 1: Force all internet traffic through Azure Firewall
az network route-table route create \
  --resource-group $RESOURCE_GROUP \
  --route-table-name rt-backend \
  --name route-internet-via-fw \
  --address-prefix 0.0.0.0/0 \
  --next-hop-type VirtualAppliance \
  --next-hop-ip-address 10.10.9.4

# Route 2: Keep VNet traffic local
az network route-table route create \
  --resource-group $RESOURCE_GROUP \
  --route-table-name rt-backend \
  --name route-vnet-local \
  --address-prefix 10.10.0.0/16 \
  --next-hop-type VnetLocal

# Attach to subnet
az network vnet subnet update \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name subnet-backend \
  --route-table rt-backend
```

**Effective routes with Option C (Azure Firewall active):**

```
Source    State    Prefix              NextHopType        NextHopIP
────────  ───────  ──────────────────  ─────────────────  ─────────
Default   Active   10.10.0.0/16        VnetLocal
User      Active   10.10.0.0/16        VnetLocal
Default   Invalid  0.0.0.0/0           Internet           ← Azure's default, overridden by UDR
User      Active   0.0.0.0/0           VirtualAppliance   10.10.9.4  ← your firewall route
Default   Active   169.254.169.254/32  Internet           ← Azure system (not overridable)
Default   Active   168.63.129.16/32    Internet
```

### Switching between options (lab workflow)

When transitioning from Option A (lab) to Option C (production / Task 08):

```bash
# Delete the TEMP direct-internet route
az network route-table route delete \
  --resource-group $RESOURCE_GROUP \
  --route-table-name rt-backend \
  --name route-internet-direct-TEMP

# Add the firewall route (after Azure Firewall is created at 10.10.9.4)
az network route-table route create \
  --resource-group $RESOURCE_GROUP \
  --route-table-name rt-backend \
  --name route-internet-via-fw \
  --address-prefix 0.0.0.0/0 \
  --next-hop-type VirtualAppliance \
  --next-hop-ip-address 10.10.9.4
```

No changes needed on subnets — the route table is already attached. Only the route entry changes.

---

## 10. Concept Comparison — When to Use What

### Security controls

| Scenario | Tool to use |
|----------|------------|
| Block port 22 from internet to subnet | **NSG** — inbound deny rule |
| Allow AGW subnet to reach backend on port 80 | **NSG** — inbound allow rule with source = 10.10.1.0/24 |
| Auto-scale VMSS without updating NSG rules | **ASG** — assign VMSS NICs to ASG, reference ASG in NSG |
| Restrict storage account to only your VNet | **Service Endpoint** + storage network rule |
| Access storage from on-prem via VPN | **Private Endpoint** — works across VPN/ExpressRoute |
| Access Key Vault from AKS pod securely | **Private Endpoint** + Private DNS Zone |

### Outbound internet access for private subnets

| Scenario | Tool to use |
|----------|------------|
| Lab — nodes need apt install, no firewall yet | **UDR** with `0.0.0.0/0 → Internet` (TEMP) |
| Simple SNAT, no traffic inspection | **NAT Gateway** |
| FQDN filtering, traffic logs, production | **Azure Firewall** + UDR pointing to Firewall IP |

### Subnet configuration rules

| Subnet purpose | NSG needed? | Route Table needed? | Delegation needed? |
|---------------|-------------|--------------------|--------------------|
| Application Gateway | ✅ Yes (allow 65200–65535 + 80/443) | ❌ No | ❌ No |
| VMSS / AKS backend nodes | ✅ Yes | ✅ Yes (control egress) | ❌ No |
| PostgreSQL Flexible Server | ❌ No (breaks provisioning) | ❌ No (breaks provisioning) | ✅ Yes |
| AKS nodes (Task 10 / APIM lab) | ✅ Optional | ❌ No (needs direct internet) | ❌ No |
| APIM (External mode) | ✅ Yes (APIM-specific rules) | ❌ No | ❌ No |
| Azure Firewall | ❌ No | ❌ No (routing loop) | ❌ No |
| VPN Gateway (GatewaySubnet) | ❌ No | ❌ No (breaks VPN) | ❌ No |

---

## Quick Reference — Route Table Recipes

### Recipe 1: Private subnet → Direct internet (Lab only)

```
Goal: subnet-backend can reach internet without a firewall
When: Tasks 01–07, firewall not yet created
```

```bash
az network route-table route create --route-table-name rt-backend \
  --name route-internet-direct-TEMP --address-prefix 0.0.0.0/0 \
  --next-hop-type Internet -g $RESOURCE_GROUP

az network route-table route create --route-table-name rt-backend \
  --name route-vnet-local --address-prefix 10.10.0.0/16 \
  --next-hop-type VnetLocal -g $RESOURCE_GROUP
```

### Recipe 2: Private subnet → Internet via Azure Firewall

```
Goal: All egress from subnet-backend inspected by firewall
When: Task 08+, firewall exists at 10.10.9.4
```

```bash
az network route-table route create --route-table-name rt-backend \
  --name route-internet-via-fw --address-prefix 0.0.0.0/0 \
  --next-hop-type VirtualAppliance --next-hop-ip-address 10.10.9.4 \
  -g $RESOURCE_GROUP

az network route-table route create --route-table-name rt-backend \
  --name route-vnet-local --address-prefix 10.10.0.0/16 \
  --next-hop-type VnetLocal -g $RESOURCE_GROUP
```

### Recipe 3: Blackhole / block all internet egress

```
Goal: subnet must not reach internet at all (air-gapped)
When: Compliance requirement, highly restricted subnet
```

```bash
az network route-table route create --route-table-name rt-restricted \
  --name route-block-internet --address-prefix 0.0.0.0/0 \
  --next-hop-type None -g $RESOURCE_GROUP

az network route-table route create --route-table-name rt-restricted \
  --name route-vnet-local --address-prefix 10.10.0.0/16 \
  --next-hop-type VnetLocal -g $RESOURCE_GROUP
```

### Recipe 4: Force specific public IP through firewall, allow rest direct

```
Goal: Traffic to 8.8.8.8 (or any specific IP) via firewall; everything else direct
When: Selective inspection for specific destinations
```

```bash
# Specific destination via firewall (more specific → wins over 0.0.0.0/0)
az network route-table route create --route-table-name rt-backend \
  --name route-dns-via-fw --address-prefix 8.8.8.8/32 \
  --next-hop-type VirtualAppliance --next-hop-ip-address 10.10.9.4 \
  -g $RESOURCE_GROUP

# Everything else → direct internet
az network route-table route create --route-table-name rt-backend \
  --name route-internet-direct --address-prefix 0.0.0.0/0 \
  --next-hop-type Internet -g $RESOURCE_GROUP
```

---

## Verify Your Configuration

### Check effective routes on a VM NIC

```bash
# Get NIC name
NIC_NAME=$(az vm show -g $RESOURCE_GROUP -n myvm --query "networkProfile.networkInterfaces[0].id" -o tsv | cut -d'/' -f9)

# View effective routes (system routes + your UDR combined)
az network nic show-effective-route-table \
  --resource-group $RESOURCE_GROUP \
  --name $NIC_NAME \
  -o table
```

### Check NSG effective rules on a NIC

```bash
az network nic list-effective-nsg \
  --resource-group $RESOURCE_GROUP \
  --name $NIC_NAME \
  -o table
```

### Verify subnet config (delegation, route table, NSG)

```bash
az network vnet subnet list \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --query "[].{Name:name, Prefix:addressPrefix, NSG:networkSecurityGroup.id, RT:routeTable.id, Delegation:delegations[0].serviceName}" \
  -o table
```
