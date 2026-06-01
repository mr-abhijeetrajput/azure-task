# Phase 00 — Overview, Network Layout & Common Resources

> **Lab:** APIM 3 — Public APIM → Private AGW → AKS (httpbin)

---

## What we are building

```
Client (Internet)
  │
  │  https://api.abhijeetrajput.life/orders   ← DNS A record → APIM public IP
  ▼
┌─────────────────────────────────────────┐
│  APIM — External VNet                   │  🔴 Public gateway
│  Custom domain: api.abhijeetrajput.life │
│  TLS terminates here (PFX on gateway)   │
│  Policies: JWT, rate limit, transform   │
│  Backend → http://10.0.3.4 (private AGW)│
└────────────────┬────────────────────────┘
                 │ http://10.0.3.4/orders/...  (VNet internal)
                 ▼
┌─────────────────────────────────────────┐
│  AGW Standard_v2 — private frontend     │  🟢 Private (10.0.3.4)
│  Dummy public IP (required, unused)     │
│  Backend pool → ILB 10.0.1.50           │
└────────────────┬────────────────────────┘
                 │ http://10.0.1.50
                 ▼
┌─────────────────────────────────────────┐
│  Azure Internal Load Balancer           │  🟢 Private
│  IP: 10.0.1.50  Port: 80               │
└────────────────┬────────────────────────┘
                 ▼
┌─────────────────────────────────────────┐
│  httpbin pod on private AKS             │  🟢 Private
│  kubectl access: VPN required           │
└─────────────────────────────────────────┘
```

**Why this lab exists:** Internet hits **APIM first**; AGW is a private routing hop before AKS.

---

## Concepts integrated

| Task | Coverage |
|---|---|
| Task 04 — SSL/TLS | Let's Encrypt + PFX on APIM (Phase 05). AGIC intentionally not used — see concept note in Phase 06. |
| Task 05 — Entra ID | JWT validation on APIM (Phase 07). AKS cluster-level RBAC → Phase 04. |
| Task 06 — PostgreSQL Private Link | Phase 08. |
| Task 09 Phase 2 — OpenVPN | VPN VM for private resource access → Phase 03. **Mandatory** — AKS is a private cluster. |
| Task 09 Phase 7 — Workload Identity | Pod reads Key Vault secret without hardcoded credentials → Phase 09. |
| Task 09 Phase 8 — Blob Storage | Blob Storage access from pod via Workload Identity → Phase 10. |

---

## Network layout

| Resource | Name | CIDR |
|---|---|---|
| Resource group | `rg-myapp` | — |
| VNet | `vnet-myapp` | `10.0.0.0/16` |
| AKS node subnet | `snet-aks` | `10.0.1.0/24` |
| APIM subnet | `snet-apim` | `10.0.2.0/24` |
| AGW subnet | `snet-agw` | `10.0.3.0/24` |
| PostgreSQL subnet | `snet-postgres` | `10.0.4.0/24` ← created in Phase 08, not here |
| Blob Storage | — | No subnet (public endpoint + RBAC) |

| Component | IP | Notes |
|---|---|---|
| APIM gateway (API traffic) | **Public** e.g. `20.x.x.x` | From APIM Overview after External deploy |
| APIM (in VNet) | `10.0.2.4` private | Also assigned in External mode |
| AGW private frontend | `10.0.3.4` | First usable IP in `snet-agw` |
| AGW dummy public IP | `pip-agw-myapp-priv` | Required by Standard_v2; no DNS, no internet access |
| AKS ILB (`orders-svc`) | `10.0.1.50` | httpbin service |
| VPN VM | `10.0.1.x` (dynamic) + Static public IP | In `snet-aks`; **mandatory** — AKS is private cluster |

| DNS | Value |
|---|---|
| Domain | `abhijeetrajput.life` |
| API subdomain | `api.abhijeetrajput.life` |
| Public A record | → APIM public IP (Hostinger) |

---

## What Phase 00 creates

```
rg-myapp
  vnet-myapp (10.0.0.0/16)
    snet-aks   10.0.1.0/24   ← AKS nodes + httpbin ILB + VPN VM
    snet-apim  10.0.2.0/24   ← APIM
    snet-agw   10.0.3.0/24   ← Application Gateway
  nsg-apim (APIM 3 rules, priority-130: Internet → 443)
  nsg-agw
  aks-myapp  (1 node, private cluster, overlay networking)
    orders deployment (httpbin)
    orders-svc  ILB 10.0.1.50
```

> `snet-postgres` (10.0.4.0/24) is created in Phase 08, not here.

---

## Resource names

| Resource | Name |
|---|---|
| APIM public IP | `pip-apim-myapp-pub` |
| AGW dummy public IP | `pip-agw-myapp-priv` |
| APIM | `apim-myapp-pub` |
| AGW | `agw-myapp-priv` |
| AKS | `aks-myapp` |
| VPN VM | `vpn-vm-apim3` |
| Key Vault | `kv-apim3-lab` |
| Storage Account | `stapim3lab` |
| Managed Identity | `wi-apim3` |

---

## Deployment order

```
00.  Overview + network layout + common resources      ← this phase
01.  Shell variables + pre-checks                      ← run at start of every session
02.  NSG verification (nsg-apim, nsg-agw)
03.  VPN VM (OpenVPN) in snet-aks                      ← MANDATORY before Phase 04
04.  Private AKS + httpbin ILB 10.0.1.50 + Entra ID RBAC
05.  APIM provisioning + TLS custom domain             ← 30–45 min
06.  Private AGW Standard_v2 → backend ILB 10.0.1.50
07.  APIM API + policies + DNS on Hostinger
08.  PostgreSQL Private Link
09.  Workload Identity + Key Vault secret from pod
10.  Blob Storage access from pod via Workload Identity
11.  End-to-end test scenarios
```

> ⚠️ **Phase 03 (VPN) must be complete and verified before Phase 04.**
> AKS is a private cluster — the API server has no public endpoint.
> `kubectl` from your laptop will not work until the VPN tunnel is up and
> Azure DNS (`168.63.129.16`) is resolving the AKS private FQDN through the tunnel.

---

## Compare with APIM 2

| Topic | APIM 2 | APIM 3 (this lab) |
|---|---|---|
| Internet entry | Public AGW | **Public APIM** |
| Middle hop | Private APIM | **Private AGW** |
| DNS A record | AGW public IP | **APIM public IP** |
| AGW SKU | WAF_v2 | **Standard_v2** (WAF_v2 optional — see Phase 06) |
| Typical production use | ✅ Common | ✅ Valid for microservices path routing |

---

## Foundation overview

| Variable | Value | Note |
|---|---|---|
| Resource Group | `rg-myapp` | Keeps APIM infra separate from other tasks |
| VNet | `vnet-myapp` (`10.0.0.0/16`) | Avoids CIDR overlap with `vnet-task01` (`10.10.0.0/16`) |
| Location | `southindia` | Same as all other tasks |

---

## Shell Variables (Run Every Session)

> Run this block at the start of **every session** before any other phase.
> All phases reference these variables.

```bash
az login

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
az account set --subscription $SUBSCRIPTION_ID

# Core
RESOURCE_GROUP="rg-myapp"
VNET_NAME="vnet-myapp"
LOCATION="southindia"

# Subnets
APIM_SUBNET="snet-apim"
AGW_SUBNET="snet-agw"
AKS_SUBNET="snet-aks"
PG_SUBNET="snet-postgres"

# Resource names
AKS_NAME="aks-myapp"
APIM_NAME="apim-myapp-pub"
AGW_NAME="agw-myapp-priv"
VPN_VM_NAME="vpn-vm-apim3"
PG_NAME="pg-task10"
KV_NAME="kv-apim3-lab"
STORAGE_NAME="stapim3lab"
WI_NAME="wi-apim3"

# Public IPs
PIP_APIM="pip-apim-myapp-pub"
PIP_AGW="pip-agw-myapp-priv"
PIP_VPN="pip-vpn-apim3"

# Subnet IDs — required for az aks create and other commands
# Note: Run this AFTER Step 0.1 creates the subnets (first-time setup only)
SUBNET_ID=$(az network vnet subnet show \
  -g $RESOURCE_GROUP --vnet-name $VNET_NAME --name $AKS_SUBNET \
  --query id -o tsv)
echo "Subnet ID: $SUBNET_ID"   # Must not be empty — if blank, run Step 0.1 first

echo "RG       : $RESOURCE_GROUP"
echo "VNet     : $VNET_NAME"
echo "Location : $LOCATION"
echo "AKS      : $AKS_NAME"
echo "APIM     : $APIM_NAME"
```

> **Note:** `WAF_POLICY` is not set — this lab uses **Standard_v2** AGW.
> For WAF_v2, add `WAF_POLICY="apim3-waf"` and see the optional section in Phase 06.

---

## Step 0.1 — Resource group + VNet + subnets

> ⚠️ First-time setup only. On subsequent sessions just run the Shell Variables block above.

```bash
az group create --name $RESOURCE_GROUP --location $LOCATION

az network vnet create \
  --resource-group $RESOURCE_GROUP \
  --name vnet-myapp \
  --address-prefixes 10.0.0.0/16 \
  --location $LOCATION

az network vnet subnet create -g $RESOURCE_GROUP --vnet-name vnet-myapp \
  --name snet-aks  --address-prefixes 10.0.1.0/24

az network vnet subnet create -g $RESOURCE_GROUP --vnet-name vnet-myapp \
  --name snet-apim --address-prefixes 10.0.2.0/24

az network vnet subnet create -g $RESOURCE_GROUP --vnet-name vnet-myapp \
  --name snet-agw  --address-prefixes 10.0.3.0/24

# snet-postgres (10.0.4.0/24) is created in Phase 08

# Verify all three subnets exist
az network vnet subnet list -g $RESOURCE_GROUP --vnet-name vnet-myapp \
  --query "[].{Name:name, CIDR:addressPrefix}" -o table
```

Expected output:

| Name | CIDR |
|---|---|
| `snet-aks` | `10.0.1.0/24` |
| `snet-apim` | `10.0.2.0/24` |
| `snet-agw` | `10.0.3.0/24` |

---

## Step 0.2 — NSG `nsg-apim`

> Priority-130 rule allows Internet → 443 directly into APIM.
> This is the APIM 3 topology: internet hits APIM first, AGW is a private internal hop.

```bash
az network nsg create -g $RESOURCE_GROUP -n nsg-apim

# Inbound — required for APIM in VNet
az network nsg rule create -g $RESOURCE_GROUP --nsg-name nsg-apim \
  --name allow-api-mgnmt --priority 100 --protocol Tcp --access Allow \
  --source-address-prefixes ApiManagement --destination-port-ranges 3443

az network nsg rule create -g $RESOURCE_GROUP --nsg-name nsg-apim \
  --name allow-vnet --priority 110 --protocol Tcp --access Allow \
  --source-address-prefixes VirtualNetwork --destination-port-ranges 443

az network nsg rule create -g $RESOURCE_GROUP --nsg-name nsg-apim \
  --name Azure-health-probe --priority 120 --protocol "*" --access Allow \
  --source-address-prefixes AzureLoadBalancer --destination-port-ranges 6390

# APIM 3: internet hits APIM directly (public entry point)
az network nsg rule create -g $RESOURCE_GROUP --nsg-name nsg-apim \
  --name allow-internet-gateway --priority 130 --protocol Tcp --access Allow \
  --source-address-prefixes Internet --destination-port-ranges 443

# Outbound
az network nsg rule create -g $RESOURCE_GROUP --nsg-name nsg-apim \
  --name allow-apim-to-storage --priority 100 --direction Outbound \
  --protocol Tcp --access Allow \
  --destination-address-prefixes Storage --destination-port-ranges 443

az network nsg rule create -g $RESOURCE_GROUP --nsg-name nsg-apim \
  --name allow-apim-to-sql --priority 110 --direction Outbound \
  --protocol Tcp --access Allow \
  --destination-address-prefixes Sql --destination-port-ranges 1443

az network nsg rule create -g $RESOURCE_GROUP --nsg-name nsg-apim \
  --name allow-apim-to-keyvault --priority 120 --direction Outbound \
  --protocol Tcp --access Allow \
  --destination-address-prefixes AzureKeyVault --destination-port-ranges 443

# APIM → private AGW
az network nsg rule create -g $RESOURCE_GROUP --nsg-name nsg-apim \
  --name allow-apim-to-agw-out --priority 140 --direction Outbound \
  --protocol Tcp --access Allow \
  --destination-address-prefixes 10.0.3.0/24 --destination-port-ranges 80

# Attach to snet-apim
az network vnet subnet update -g $RESOURCE_GROUP --vnet-name vnet-myapp \
  --name snet-apim --network-security-group nsg-apim
```

---

## Step 0.3 — NSG `nsg-agw`

```bash
az network nsg create -g $RESOURCE_GROUP -n nsg-agw

# APIM subnet → AGW port 80
az network nsg rule create -g $RESOURCE_GROUP --nsg-name nsg-agw \
  --name allow-apim-to-agw --priority 100 --protocol Tcp --access Allow \
  --source-address-prefixes 10.0.2.0/24 --destination-port-ranges 80

# MANDATORY for Standard_v2 / WAF_v2 — Azure control plane
# Portal blocks AGW creation if this rule is missing
az network nsg rule create -g $RESOURCE_GROUP --nsg-name nsg-agw \
  --name allow-agw-infra --priority 105 --protocol Tcp --access Allow \
  --direction Inbound \
  --source-address-prefixes GatewayManager \
  --destination-address-prefixes '*' \
  --destination-port-ranges 65200-65535

az network nsg rule create -g $RESOURCE_GROUP --nsg-name nsg-agw \
  --name Azure-health-probe --priority 115 --protocol "*" --access Allow \
  --direction Inbound \
  --source-address-prefixes AzureLoadBalancer --destination-port-ranges 6390

az network nsg rule create -g $RESOURCE_GROUP --nsg-name nsg-agw \
  --name allow-vnet --priority 120 --protocol "*" --access Allow \
  --direction Inbound \
  --source-address-prefixes VirtualNetwork --destination-port-ranges "*"

az network vnet subnet update -g $RESOURCE_GROUP --vnet-name vnet-myapp \
  --name snet-agw --network-security-group nsg-agw
```

> ⚠️ `allow-agw-infra` (priority 105, source `GatewayManager`, ports 65200–65535) is
> **mandatory**. Azure Portal blocks AGW creation if this rule is missing.

---

## Step 0.4 — AKS private cluster + httpbin ILB

> ⚠️ AKS is created as a **private cluster** from the start.
> The API server has no public endpoint — only reachable from inside `vnet-myapp`.
> **Complete Phase 03 (VPN) and verify the tunnel is working before running any `kubectl` command.**

### Node sizing

| | Value |
|---|---|
| Node count | 1 |
| Node size | `Standard_D2ls_v5` — 2 vCPU, 4 GiB |
| Why 1 node | httpbin + test pods are lightweight; no multi-node requirement |

> **vCPU quota note:** The AKS node (`Standard_D2ls_v5`) uses 2 vCPU from the **DLSv5 family**.
> The VPN VM (Phase 03) uses `Standard_B2ts_v2` — 2 vCPU from the **BS family**.
> These are separate quota buckets, but both count toward the regional vCPU total.
> Check both families before proceeding:
> ```bash
> az vm list-usage --location southindia \
>   --query "[?contains(name.value,'standardDLSv5Family') || contains(name.value,'standardBSFamily')].{Name:name.localizedValue, Used:currentValue, Limit:limit}" \
>   -o table
> ```
> If either family has insufficient quota, request an increase:
> `Azure Portal → Subscriptions → Usage + quotas → Request increase`

```bash
# Resolve subnet ID first to avoid nested substitution issues in Cloud Shell
SUBNET_ID=$(az network vnet subnet show \
  -g $RESOURCE_GROUP \
  --vnet-name vnet-myapp \
  --name snet-aks \
  --query id -o tsv)
echo "Subnet ID: $SUBNET_ID"   # Must not be empty — if blank, run Step 0.1 first

az aks create \
  --resource-group $RESOURCE_GROUP \
  --name aks-myapp \
  --location $LOCATION \
  --node-count 1 \
  --node-vm-size Standard_D2ls_v5 \
  --network-plugin azure \
  --network-plugin-mode overlay \
  --network-policy none \
  --pod-cidr 192.168.0.0/16 \
  --vnet-subnet-id $SUBNET_ID \
  --service-cidr 10.100.0.0/16 \
  --dns-service-ip 10.100.0.10 \
  --enable-private-cluster \
  --dns-name-prefix aks-myapp \
  --enable-aad \
  --enable-azure-rbac \
  --generate-ssh-keys
# ⏱ 5–10 minutes
```
```
Why both together
Flag                   Controls                                      Layer
--enable-aad           Authentication  proves identity via Entra ID  Who are you?--enable-azure-rbac    Authorization  what that identity can do      What can you do?
```
**IP ranges used by this cluster:**

| Range | CIDR | Purpose |
|---|---|---|
| `snet-aks` | `10.0.1.0/24` | Node IPs (overlay — pods don't consume VNet IPs) |
| Pod CIDR | `192.168.0.0/16` | Pod IPs (not routed in VNet) |
| Service CIDR | `10.100.0.0/16` | Kubernetes ClusterIP services |
| DNS service IP | `10.100.0.10` | kube-dns inside cluster |

### Verify private cluster

```bash
az aks show \
  --resource-group $RESOURCE_GROUP \
  --name aks-myapp \
  --query "{PrivateCluster:apiServerAccessProfile.enablePrivateCluster, PrivateFQDN:privateFqdn}" \
  -o table
# PrivateCluster : true  ✅
# PrivateFQDN    : aks-myapp.hcp.southindia.azmk8s.io  (resolves to 10.0.x.x inside VNet only)
```

### Get credentials

> ⚠️ `az aks get-credentials` itself works without VPN (just downloads kubeconfig).
> But **every `kubectl` command requires VPN to be connected** and Azure DNS resolving correctly.

```bash
az aks get-credentials --resource-group $RESOURCE_GROUP --name aks-myapp \
  --overwrite-existing --admin

# Only run AFTER Phase 03 VPN is connected and verified:
kubectl get nodes
# Expected: 1 node in Ready state ✅
# Hangs or fails → VPN not connected or Azure DNS not resolving → see Phase 03 troubleshooting
```

## Phase 00 complete?

⬜ VNet + 3 subnets created (`snet-aks`, `snet-apim`, `snet-agw`)
⬜ `nsg-apim` and `nsg-agw` created and attached to their subnets
⬜ AKS **private** cluster created (`enablePrivateCluster: true`)
⬜ `orders-svc` ILB at `10.0.1.50` — deploy **after** Phase 03 VPN is up and verified
⬜ Shell variables set

---

## Pre-checks (Run Every Session)

### snet-apim must have no delegation

```bash
az network vnet subnet show \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name $APIM_SUBNET \
  --query "delegations" -o json
# Expected: []
# If NOT empty:
az network vnet subnet update \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name $APIM_SUBNET \
  --remove delegations
```

### Required subnets exist

```bash
for SUBNET in snet-aks snet-apim snet-agw; do
  STATE=$(az network vnet subnet show \
    --resource-group $RESOURCE_GROUP \
    --vnet-name $VNET_NAME \
    --name $SUBNET \
    --query provisioningState -o tsv 2>/dev/null)
  echo "$SUBNET : ${STATE:-NOT FOUND}"
done
# All must show: Succeeded
```
