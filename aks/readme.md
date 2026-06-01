# APIM 3 — Public APIM → Private AGW → AKS (httpbin)

### `api.abhijeetrajput.life/orders` → **APIM (public)** → **AGW (private)** → Internal Load Balancer → httpbin pod

> **Request flow diagrams:** [straight-apim3.md](./straight-apim3.md)

> **Companion lab:** [# APIM 2.md](./#%20APIM%202.md) uses the inverse pattern (public AGW → private APIM). Run **one** lab at a time in the same resource group, or use a separate RG to avoid name conflicts.

> **Shared VNet / AKS / setup:** [common-resources.md](./common-resources.md) — complete APIM 2 first, tear down APIM 2-only resources, then this lab.

---

## What we are building

```
Client (Internet)
  │
  │  https://api.abhijeetrajput.life/orders   ← DNS points to APIM public IP
  ▼
┌─────────────────────────────────────────┐
│  APIM — External VNet                   │  🔴 Public gateway
│  Custom domain: api.abhijeetrajput.life │
│  TLS terminates here (PFX on gateway)   │
│  Policies: JWT, rate limit, transform    │
│  Backend → http://10.0.3.4 (private AGW) │
└────────────────┬────────────────────────┘
                 │ http://10.0.3.4/orders/...  (VNet internal)
                 ▼
┌─────────────────────────────────────────┐
│  AGW WAF_v2 — private frontend active   │  🟢 Private (10.0.3.4)
│  Dummy public IP (required, unused)     │
│  WAF: apim3-waf (Detection mode)        │
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
└─────────────────────────────────────────┘
```

**Why this lab exists:** Compare layer order with APIM 2. Here the **internet hits APIM first**; AGW is an internal hop before AKS.

> **Concepts integrated from:**
> - Task 04 — SSL/TLS → already implemented (Step 3, Let's Encrypt + PFX on APIM). AGIC is intentionally not used here — see concept note in Step 4.
> - Task 05 — Entra ID: JWT validation on APIM (Step 5.3) covers API-level auth. AKS cluster-level RBAC (users/groups/kubectl access) → Step 1a.
> - Task 06 — PostgreSQL Private Link → Step 8.
> - Task 09 Phase 2 — OpenVPN on VM for private resource access → Step 0.3.
> - Task 09 Phase 7 — Workload Identity: pod reads Key Vault secret without hardcoded credentials → Step 9.
> - Task 09 Phase 8 — Blob Storage access from pod via Workload Identity → Step 10.

**Why httpbin:** Same as APIM 2 — `/headers`, `/ip`, `/post` prove policy and routing without custom code.

**Why HTTP APIM → AGW → ILB:** TLS ends at APIM for clients. Internal hops stay HTTP inside the VNet for POC simplicity.

> ⚠️ **Not the usual production pattern.** Internet hits APIM first; AGW sits behind APIM for path-based routing + OWASP WAF (Detection mode). Edge security = APIM policies (JWT, rate limit) + AGW WAF_v2. For WAF at the very edge before APIM, use [APIM 2](./#%20APIM%202.md) (public **WAF** AGW → private APIM).

---

## Network layout

| Resource | Name | CIDR |
|---|---|---|
| Resource group | `rg-myapp` | — |
| VNet | `vnet-myapp` | `10.0.0.0/16` |
| AKS node subnet | `snet-aks` | `10.0.1.0/24` |
| APIM subnet | `snet-apim` | `10.0.2.0/24` |
| AGW subnet | `snet-agw` | `10.0.3.0/24` |
| PostgreSQL subnet | `snet-postgres` | `10.0.4.0/24` |
| Blob Storage | — | No subnet (public endpoint + RBAC) |

| Component | IP | Notes |
|---|---|---|
| APIM gateway (API traffic) | **Public** e.g. `20.x.x.x` | From APIM Overview after **External** deploy |
| APIM (in VNet) | `10.0.2.4` private | Also assigned in External mode |
| AGW private frontend | `10.0.3.4` | First usable in `snet-agw` |
| AGW dummy public IP | `pip-agw-myapp-priv` | Required by WAF_v2; no DNS, NSG blocks internet |
| AKS ILB (`orders-svc`) | `10.0.1.50` | Same httpbin service as APIM 2 |
| VPN VM | `10.0.1.x` (dynamic) + Static public IP | In snet-aks; used to access private IPs from laptop |

| DNS | Value |
|---|---|
| Domain | `abhijeetrajput.life` |
| API subdomain | `api.abhijeetrajput.life` |
| **Public A record** | → **APIM public IP** (Hostinger) |
| DNS provider | Hostinger |

### Resource names (this lab)

| Resource | Name | APIM 2 equivalent |
|---|---|---|
| APIM public IP | `pip-apim-myapp-pub` | `pip-agw-myapp` (AGW's IP in APIM 2) |
| AGW dummy public IP | `pip-agw-myapp-priv` | — (required by WAF_v2, unused) |
| APIM | `apim-myapp-pub` | `apim-myapp` |
| AGW | `agw-myapp-priv` | `agw-myapp` |
| WAF policy | `apim3-waf` | — |
| AKS | `aks-myapp` | same (reuse cluster + httpbin) |
| VPN VM | `vpn-vm-apim3` | — (new for this lab) |
| Key Vault | `kv-apim3-lab` | — (new for this lab) |
| Storage Account | `stapim3lab` | — (new for this lab) |
| Managed Identity | `wi-apim3` | — (new for this lab) |

---

## Deployment order

```
0. VNet + subnets + NSGs (nsg-apim, nsg-agw)      ← already exist from common-resources.md
0.3 VPN VM (OpenVPN) in snet-aks                  ← NEW: access private IPs from laptop
1. AKS + httpbin ILB 10.0.1.50                    ← reuse from APIM 2 if already done
   1a. Entra ID RBAC on AKS cluster
2. Public IP pip-apim-myapp-pub (with DNS label)   ← must exist before APIM wizard
3. APIM External (public gateway)                  ← 30–45 min
4. Custom domain + TLS cert on APIM
5. Public IP pip-agw-myapp-priv (dummy for WAF_v2) ← must exist before AGW wizard
   Private AGW WAF_v2 → backend ILB 10.0.1.50
6. APIM API + policies (backend = AGW private IP 10.0.3.4)
7. DNS on Hostinger → APIM public IP
8. PostgreSQL Private Link
9. Workload Identity + Key Vault secret from pod
10. Blob Storage access from pod via Workload Identity
11. Test scenarios
```

---

## Step 0 — VNet, subnets, NSGs

> ✅ **VNet and subnets already exist.** `vnet-myapp`, `snet-aks` (10.0.1.0/24),
> `snet-apim` (10.0.2.0/24), and `snet-agw` (10.0.3.0/24) were all created in
> the common resources (`common-resources.md`). Do NOT recreate them.
> Set your shell variables before running any command below:
>
> ```bash
> RESOURCE_GROUP="rg-myapp"
> VNET_NAME="vnet-myapp"
> LOCATION="southindia"
> ```

> ⚠️ **Pre-check: verify `snet-apim` has no subnet delegation before creating APIM.**
> If a delegation exists from a previous failed deployment, the `az apim create` command
> will fail silently or error. Remove it first:
>
> ```bash
> # Check for delegations
> az network vnet subnet show \
>   --resource-group rg-myapp \
>   --vnet-name vnet-myapp \
>   --name snet-apim \
>   --query "delegations" -o json
> # Expected: []
> # If not empty — remove delegation before proceeding:
> az network vnet subnet update \
>   --resource-group rg-myapp \
>   --vnet-name vnet-myapp \
>   --name snet-apim \
>   --remove delegations
> ```

### 0.1 Additional NSG for AGW subnet (`nsg-agw`)

> ✅ `nsg-agw` is already created and attached to `snet-agw` in `common-resources.md` Phase 0.3.
> Verify it's in place before continuing:
>
> ```bash
> az network nsg show -g rg-myapp -n nsg-agw --query "securityRules[].name" -o tsv
> # Expected: allow-apim-to-agw, Azure-health-probe, allow-vnet
> ```

For reference, the rules already applied are:

| Name | Priority | Source | Port | Action | Purpose |
|---|---|---|---|---|---|
| `allow-apim-to-agw` | 100 | `10.0.2.0/24` | 80 | Allow | APIM subnet → AGW |
| `allow-agw-infra` | 105 | `GatewayManager` | 65200-65535 | Allow | WAF_v2 control plane (mandatory) |
| `Azure-health-probe` | 115 | `AzureLoadBalancer` | 6390 | Allow | AGW health |
| `allow-vnet` | 120 | `VirtualNetwork` | * | Allow | Intra-VNet |

> ⚠️ **`allow-agw-infra` is mandatory for WAF_v2.** Azure Portal blocks AGW creation if `GatewayManager → 65200-65535` is denied.

**Outbound:** allow to `VirtualNetwork` and backend `10.0.1.0/24`.

If you need to recreate manually:

```bash
az network nsg create --resource-group rg-myapp --name nsg-agw

az network nsg rule create --resource-group rg-myapp --nsg-name nsg-agw \
  --name allow-apim-to-agw --priority 100 --protocol Tcp --access Allow \
  --source-address-prefixes 10.0.2.0/24 --destination-port-ranges 80

# Mandatory for WAF_v2 — Azure control plane ports
az network nsg rule create --resource-group rg-myapp --nsg-name nsg-agw \
  --name allow-agw-infra --priority 105 --protocol Tcp --access Allow \
  --direction Inbound \
  --source-address-prefixes GatewayManager \
  --destination-address-prefixes '*' \
  --destination-port-ranges 65200-65535

az network nsg rule create --resource-group rg-myapp --nsg-name nsg-agw \
  --name Azure-health-probe --priority 115 --protocol "*" --access Allow \
  --source-address-prefixes AzureLoadBalancer --destination-port-ranges 6390

az network vnet subnet update \
  --resource-group rg-myapp --vnet-name vnet-myapp --name snet-agw \
  --network-security-group nsg-agw
```

### 0.2 APIM subnet NSG (`nsg-apim`)

> ✅ Base `nsg-apim` rules are already created in `common-resources.md` Phase 0.2.
> For APIM 3 you need the `allow-internet-gateway` rule at priority 130 (not the APIM 2 rule).
> The teardown script in Phase 2 of `common-resources.md` handles this swap.

The APIM 3-specific inbound rule that must be active at priority 130:

| Name | Priority | Source | Port | Purpose |
|---|---|---|---|---|
| `allow-internet-gateway` | 130 | `Internet` | 443 | Public clients → APIM gateway |

And the outbound rule (add if not present):

| Name | Priority | Direction | Destination | Port | Purpose |
|---|---|---|---|---|---|
| `allow-apim-to-agw-out` | 140 | Outbound | `10.0.3.0/24` | 80 | APIM → private AGW |

Keep `allow-api-mgnmt`, `allow-vnet`, `Azure-health-probe`, and outbound Storage/Sql/KeyVault rules from the common base.

---

## Step 0.3 — VPN VM (OpenVPN) for Private Resource Access

### Why VPN in this lab

This lab has several private resources that are only reachable inside `vnet-myapp`:
- AGW private frontend `10.0.3.4` — no public IP for debugging
- AKS ILB `10.0.1.50` — internal only
- PostgreSQL `10.0.4.x` — no public access
- Key Vault private endpoint (Step 9)

Without VPN, you can only reach APIM's public IP. With VPN, your laptop is inside the VNet and you can `curl 10.0.3.4`, `psql` directly to PostgreSQL, and run `kubectl` if needed.

```
Your laptop
  ↓ OpenVPN tunnel (UDP 1194)
vpn-vm-apim3 (10.0.1.x in snet-aks, Static public IP)
  ↓ IP forwarding
vnet-myapp (10.0.0.0/16)
  ↓
curl http://10.0.3.4/get          → AGW private ✅
psql pg-task10.postgres...         → PostgreSQL ✅
kubectl get pods                   → AKS (if Entra ID auth done) ✅
```

### Step 0.3.1 — Create VPN VM

```bash
VPN_VM_NAME="vpn-vm-apim3"
```

**Portal:**
```
Virtual Machines → Create → Azure Virtual Machine

── Basics ────────────────────────────────────────────
   Resource Group    → rg-myapp
   VM Name           → vpn-vm-apim3
   Region            → South India
   Image             → Ubuntu Server 24.04 LTS - Gen2
   Size              → Standard_B2ts_v2 (2 vCPU, 1 GiB — fine for VPN)
   Authentication    → Password
   Username          → azureuser
   Security type     → Trusted launch

── Networking ────────────────────────────────────────
   Virtual network   → vnet-myapp
   Subnet            → snet-aks (10.0.1.0/24)
   Public IP         → Create new
                        Name: pip-vpn-apim3
                        SKU: Standard
                        Assignment: Static   ← CRITICAL: must be static
   Accelerated networking → On
   Delete NIC when VM deleted → Enabled
   OS disk type      → Premium SSD LRS

→ Review + Create → Create
```

**CLI:**
```bash
az vm create \
  --resource-group $RESOURCE_GROUP \
  --name $VPN_VM_NAME \
  --location $LOCATION \
  --image Ubuntu2404 \
  --size Standard_B2ts_v2 \
  --vnet-name $VNET_NAME \
  --subnet snet-aks \
  --public-ip-address pip-vpn-apim3 \
  --public-ip-sku Standard \
  --public-ip-address-allocation Static \
  --admin-username azureuser \
  --admin-password 'VpnAdmin@Apim3!'
```

### Step 0.3.2 — Enable IP Forwarding on VM NIC

```
⚠️  Required — allows VM to route packets between the VPN tunnel and the VNet

Portal:
  Virtual Machines → vpn-vm-apim3 → Networking
  → Click the NIC name (vpn-vm-apim3-nic)
  → Settings → IP configurations
  → Enable IP forwarding → toggle ON → Save
```

**CLI:**
```bash
NIC_ID=$(az vm show \
  --resource-group $RESOURCE_GROUP \
  --name $VPN_VM_NAME \
  --query "networkProfile.networkInterfaces[0].id" -o tsv)

az network nic update \
  --ids $NIC_ID \
  --ip-forwarding true
```

### Step 0.3.3 — NSG: Allow OpenVPN Port 1194

```bash
# Find the NSG on snet-aks (or the VM NIC NSG)
az network nsg rule create \
  --resource-group $RESOURCE_GROUP \
  --nsg-name nsg-aks \
  --name Allow-OpenVPN \
  --priority 100 \
  --protocol Udp \
  --destination-port-ranges 1194 \
  --access Allow \
  --direction Inbound
```

**Portal:**
```
Network Security Groups → nsg-aks → Inbound security rules → + Add
   Source               → Any
   Source port ranges   → *
   Destination port     → 1194
   Protocol             → UDP
   Action               → Allow
   Priority             → 100
   Name                 → Allow-OpenVPN
   → Add
```

### Step 0.3.4 — Install OpenVPN on the VM

```bash
# Get VM public IP
VPN_PUBLIC_IP=$(az network public-ip show \
  --resource-group $RESOURCE_GROUP \
  --name pip-vpn-apim3 \
  --query ipAddress -o tsv)

echo "VPN VM public IP: $VPN_PUBLIC_IP"

# SSH into VM
ssh azureuser@$VPN_PUBLIC_IP
```

Once inside the VM:

```bash
# Enable OS-level IP forwarding
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# Download and run angristan's installer
wget https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh
chmod +x openvpn-install.sh
sudo bash openvpn-install.sh
```

**Installer prompts:**
```
IP address: <auto-detected public IP>   → press Enter ✅

Protocol: UDP or TCP?
→ Choose 1 (UDP)

Port: [1194]
→ press Enter (keep default)

DNS resolver:
→ Choose 11 (Custom)
  Primary DNS:   168.63.129.16   ← Azure DNS — resolves privatelink zones + internal names
  Secondary DNS: 8.8.8.8         ← fallback for public DNS

Enable compression? → n
Customize encryption? → n
Client name: → apim3-client

→ Generates /root/apim3-client.ovpn
```

> **Why Azure DNS as primary (168.63.129.16):**
> Once on VPN, you want to resolve `pg-task10.private.postgres.database.azure.com` to
> its private IP (`10.0.4.x`), and any other privatelink zones in this VNet.
> Azure DNS handles this automatically when queried from inside the VNet.
> In Task 09 the primary DNS was K8s DNS (`10.96.0.10`) because private AKS cluster
> needed `cluster.local` resolution. Here AKS is not private — Azure DNS is sufficient.

### Step 0.3.5 — Download .ovpn File

```bash
# From your LOCAL machine (not the VM)
scp azureuser@$VPN_PUBLIC_IP:/root/apim3-client.ovpn ~/apim3-client.ovpn
```

### Step 0.3.6 — Connect from Laptop

**Windows / Mac:**
```
1. Download OpenVPN Connect: https://openvpn.net/client/
2. Import → apim3-client.ovpn
3. Click Connect ✅
```

**Linux:**
```bash
sudo apt install openvpn -y
sudo openvpn --config ~/apim3-client.ovpn
```

### VPN Verification Checklist

```bash
# After connecting:
ping 10.0.1.1       # VNet gateway reachable ✅
ping 10.0.3.4       # AGW private IP reachable (after AGW created) ✅

# Test AGW directly from laptop (bypassing APIM)
curl http://10.0.3.4/get
# Expected: httpbin JSON ✅  (confirms AGW → ILB → pod chain works)

# Test PostgreSQL from laptop (after Step 8)
psql -h pg-task10.postgres.database.azure.com -U pgadmin -d postgres
# Must connect → confirms DNS resolves to 10.0.4.x via Azure DNS ✅
```

---

## Step 1 — AKS + httpbin (same as APIM 2)

### Step 1a — AKS Entra ID RBAC (from Task 05)

**Concept:**
The AKS cluster (`aks-myapp`) is created in `common-resources.md`. This step adds Entra ID user/group access control on top of it — separate from the JWT validation APIM does on the API. These are two different layers:

```
Layer 1 — API-level auth (Task 05 APIM equivalent):
  Client → APIM → validate-jwt policy checks Entra token for aud=api://orders
  Covered in Step 5.3 of this lab ✅

Layer 2 — Cluster-level auth (Task 05 kubectl RBAC):
  Engineer → kubectl → Entra ID token → AKS RBAC role check
  Covered here ↓

Both use Entra ID but control completely different things:
  APIM JWT   = who can call the Orders API
  AKS RBAC   = who can run kubectl on the cluster
```

#### Enable Entra ID Auth on AKS (if not already on)

```bash
# Check current auth mode
az aks show \
  --resource-group $RESOURCE_GROUP \
  --name aks-myapp \
  --query "aadProfile" -o json
# If output is null → Entra ID not enabled, run below
# If managed:true, enableAzureRBAC:true → already enabled, skip to user creation

# Enable Entra ID + Azure RBAC on existing cluster
az aks update \
  --resource-group $RESOURCE_GROUP \
  --name aks-myapp \
  --enable-aad \
  --enable-azure-rbac
# ⚠️ API server restarts — kubectl unavailable for 2–3 minutes
```

#### Assign Yourself Cluster Admin First

```bash
AKS_ID=$(az aks show \
  --resource-group $RESOURCE_GROUP \
  --name aks-myapp \
  --query id -o tsv)

MY_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)

az role assignment create \
  --role "Azure Kubernetes Service RBAC Cluster Admin" \
  --assignee-object-id $MY_OBJECT_ID \
  --assignee-principal-type User \
  --scope $AKS_ID
```

#### Create Test Users and Group

```bash
# Create platform engineer (cluster admin)
az ad user create \
  --display-name "Platform Engineer" \
  --user-principal-name platformeng@<yourtenant>.onmicrosoft.com \
  --password "PlatEng@Task10" \
  --force-change-password-next-sign-in false

# Create backend dev (scoped to orders namespace only)
az ad user create \
  --display-name "Backend Dev" \
  --user-principal-name backenddev@<yourtenant>.onmicrosoft.com \
  --password "BackDev@Task10" \
  --force-change-password-next-sign-in false

# Create security group (MUST be Security type, not M365)
az ad group create \
  --display-name "aks-orders-team" \
  --mail-nickname "aks-orders-team"

GROUP_ID=$(az ad group show --group "aks-orders-team" --query id -o tsv)
DEV_ID=$(az ad user show --id backenddev@<yourtenant>.onmicrosoft.com --query id -o tsv)

az ad group member add --group "aks-orders-team" --member-id $DEV_ID
```

#### Create Namespace and Assign Scoped Roles

```bash
# Create orders namespace
kubectl create namespace orders

# Assign backend dev group → Admin scoped to orders namespace only
az role assignment create \
  --role "Azure Kubernetes Service RBAC Admin" \
  --assignee-object-id $GROUP_ID \
  --assignee-principal-type Group \
  --scope "$AKS_ID/namespaces/orders"

# Verify
az role assignment list --scope "$AKS_ID/namespaces/orders" \
  --query "[].{Principal:principalName, Role:roleDefinitionName}" -o table
```

#### Test Access

```bash
# As backend dev — orders namespace only
az login --username backenddev@<yourtenant>.onmicrosoft.com --password "BackDev@Task10"
az aks get-credentials --resource-group $RESOURCE_GROUP --name aks-myapp --overwrite-existing
sudo az aks install-cli   # installs kubelogin

kubectl -n orders get pods     # ✅ Works
kubectl -n default get pods   # ❌ Forbidden — scoped to orders only

# Switch back to your admin account
az login
az aks get-credentials --resource-group $RESOURCE_GROUP --name aks-myapp --overwrite-existing
```

> **Why two Entra ID checks matter in this lab:**
> APIM JWT validates the *caller's identity* — a valid token lets them call the API.
> AKS RBAC controls *who can kubectl* into the cluster — a completely separate control plane.
> In production both are always needed. An attacker with a stolen JWT can call the API but still cannot access the cluster.

If you already completed **Step 0.4** in `common-resources.md`, verify:

```bash
kubectl get svc orders-svc
# EXTERNAL-IP   10.0.1.50
```

Otherwise follow **Phase 0.4** in [common-resources.md](./common-resources.md) (`aks-myapp`, httpbin, ILB `10.0.1.50`).

---

## Step 2 — Provision APIM in **External** VNet mode (public gateway)

> ⏱ **30–45 minutes.** Start before AGW.

### Why APIM is public here

- **External** mode: gateway has a **public IP** for API traffic.
- Clients use **Hostinger DNS → APIM public IP**.
- APIM forwards to **private AGW** `10.0.3.4`, then to ILB.

### 2.0 Create Public IP for APIM gateway

> **Why a separate step:** Azure requires the Public IP to exist — and to have a **DNS label
> (FQDN)** — before you can select it in the APIM creation wizard when using External VNet mode.
> If you skip this and let the Portal auto-assign an IP (e.g. one from the AKS managed resource
> group `MC_rg-myapp_aks-myapp_southindia`), provisioning fails with:
>
> `Public IP Address resource must have a Fully Qualified Domain Name of an A DNS record
> associated with the public IP.`
>
> Always create a dedicated IP in `rg-myapp` — never reuse the AKS-managed IP. AKS owns
> that IP and can modify or delete it independently of your APIM instance.

**Portal:** `Create a resource` → `Public IP address`

| Field | Value |
|---|---|
| Name | `pip-apim-myapp-pub` |
| Resource group | `rg-myapp` |
| Region | `South India` |
| SKU | `Standard` |
| Assignment | `Static` |
| DNS name label | `apim-myapp-pub` |

> The DNS label gives APIM the required FQDN: `apim-myapp-pub.southindia.cloudapp.azure.com`

**CLI:**
```bash
az network public-ip create \
  --name pip-apim-myapp-pub \
  --resource-group rg-myapp \
  --location southindia \
  --sku Standard \
  --allocation-method Static \
  --dns-name apim-myapp-pub

# Verify FQDN was assigned
az network public-ip show \
  --resource-group rg-myapp \
  --name pip-apim-myapp-pub \
  --query "{IP:ipAddress, FQDN:dnsSettings.fqdn}" -o table
# Expected: IP: 20.x.x.x   FQDN: apim-myapp-pub.southindia.cloudapp.azure.com
```

---

### 2.1 Create APIM

**Portal:** `API Management` → `Create`

| Tab | Field | Value |
|---|---|---|
| Basics | Resource name | `apim-myapp-pub` |
| Basics | Pricing tier | `Developer` (POC) |
| Basics | **Availability zones** | **`None` / uncheck all** ← Developer tier does not support zones; leaving this on causes activation failure |
| Basics | Virtual network | `Virtual network` |
| Basics | **Type** | **`External`** |
| Basics | VNet | `vnet-myapp` |
| Basics | Subnet | `snet-apim` |
| Basics | **Public IP Address** | **`pip-apim-myapp-pub`** ← select the IP created in Step 2.0 |
| **Managed Identity** | **System assigned** | **`On`** ← enable this |

> **Why enable System Assigned Managed Identity:**
> - Required if you want APIM to fetch the TLS certificate from **Azure Key Vault**
>   instead of uploading a PFX file directly.
> - Required if any APIM policy references secrets stored in Key Vault (named values).
> - Costs nothing — always enable it at creation time. You cannot easily add Key Vault
>   cert rotation later without it.
> - The managed identity is tied to the lifecycle of this APIM instance — deleted with it.

**CLI:**
```bash
az apim create \
  --resource-group rg-myapp \
  --name apim-myapp-pub \
  --location southindia \
  --publisher-name "My Company" \
  --publisher-email admin@abhijeetrajput.life \
  --sku-name Developer \
  --virtual-network-type External \
  --virtual-network-id /subscriptions/<sub-id>/resourceGroups/rg-myapp/providers/Microsoft.Network/virtualNetworks/vnet-myapp \
  --subnet-name snet-apim \
  --public-ip-address pip-apim-myapp-pub \
  --enable-managed-identity
```

### 2.2 Note APIM **public** gateway IP

**Portal:** `apim-myapp-pub` → **Overview** → **Public IP address** (gateway)

**CLI:**
```bash
az apim show \
  --resource-group rg-myapp \
  --name apim-myapp-pub \
  --query "publicIpAddresses" -o tsv
# Example: 20.193.x.x  ← use for Hostinger A record in Step 7
```

Also note private IP (for jump-box tests):

```bash
az apim show \
  --resource-group rg-myapp \
  --name apim-myapp-pub \
  --query "privateIpAddresses" -o tsv
# Expected: 10.0.2.4
```

---

## Step 3 — Custom domain + TLS on APIM (clients hit this hostname)

Internet clients call `https://api.abhijeetrajput.life` — certificate must be on **APIM Gateway**, not AGW.

### 3.1 Get a TLS certificate via Let's Encrypt (DNS challenge)

**Why DNS challenge (not HTTP):** APIM is inside a VNet — Let's Encrypt cannot reach
`api.abhijeetrajput.life` over HTTP to verify ownership. DNS challenge adds a TXT record in
Hostinger instead — no public server needed.

**Prerequisites:** WSL / Ubuntu / macOS with `certbot`, access to Hostinger hPanel.

#### Install certbot

```bash
sudo apt update && sudo apt install certbot -y   # Ubuntu / WSL
# macOS: brew install certbot
certbot --version
```

#### Run certbot in manual DNS mode

```bash
sudo certbot certonly \
  --manual \
  --preferred-challenges dns \
  -d api.abhijeetrajput.life
```

Enter your email, agree to terms. Certbot pauses and prints a TXT record value — **do not press Enter yet.**

#### Add TXT record in Hostinger hPanel

`hpanel.hostinger.com` → `Domains` → `abhijeetrajput.life` → `DNS / Nameservers` → `Add Record`:

| Field | Value |
|---|---|
| Type | `TXT` |
| Name | `_acme-challenge.api` |
| Value | paste the token certbot printed |
| TTL | `300` |

Click **Add**.

#### Verify propagation before continuing

```bash
dig TXT _acme-challenge.api.abhijeetrajput.life +short
# Must return your token — wait 2–5 min for Hostinger to propagate
```

Only press **Enter** in certbot once `dig` shows the token.

Cert files saved to `/etc/letsencrypt/live/api.abhijeetrajput.life/`.

#### Export as PFX (required for APIM)

```bash
sudo openssl pkcs12 -export \
  -in /etc/letsencrypt/live/api.abhijeetrajput.life/fullchain.pem \
  -inkey /etc/letsencrypt/live/api.abhijeetrajput.life/privkey.pem \
  -out ~/api.abhijeetrajput.life.pfx \
  -passout pass:YourPFXPassword

# Verify the PFX is valid — no output = good
openssl pkcs12 -in ~/api.abhijeetrajput.life.pfx \
  -passin pass:YourPFXPassword -noout
```

#### Copy to Windows (if using WSL)

```bash
cp ~/api.abhijeetrajput.life.pfx /mnt/c/Users/<your-username>/Desktop/
```

> **Cert expiry:** Let's Encrypt certs expire in **90 days**. Re-run certbot, export a new PFX,
> and re-upload to APIM when it nears expiry. For production, use Key Vault with auto-rotation
> (requires the managed identity enabled in Step 2.1).

---

### 3.2 Upload certificate to APIM

**Portal:** `apim-myapp-pub` → `Deployment + infrastructure` → `Custom domains` → `+ Add`

| Field | Value |
|---|---|
| Type | `Gateway` |
| Hostname | `api.abhijeetrajput.life` |
| Certificate | **Custom** → upload `api.abhijeetrajput.life.pfx` |
| Certificate password | `YourPFXPassword` |
| Negotiate client certificate | `Off` |
| Default SSL binding | `On` |

Click **Save** — takes 3–5 minutes.

> **Alternative — Key Vault cert (requires managed identity from Step 2.1):**
> Instead of uploading PFX directly, select **Key Vault** → pick your cert from KV.
> APIM uses its system-assigned managed identity to fetch and auto-renew the cert.
> This is the production-recommended approach.

**CLI:**
```bash
CERT_B64=$(base64 -w 0 ~/api.abhijeetrajput.life.pfx)

az apim update \
  --resource-group rg-myapp \
  --name apim-myapp-pub \
  --hostname-configurations '[{
    "type": "Proxy",
    "hostName": "api.abhijeetrajput.life",
    "negotiateClientCertificate": false,
    "defaultSslBinding": true,
    "certificatePassword": "YourPFXPassword",
    "encodedCertificate": "'"$CERT_B64"'"
  }]'
```

#### Verify custom domain is active

```bash
# From your laptop — should resolve to APIM public IP and return 401 (no JWT)
curl -sk -o /dev/null -w "HTTP %{http_code}\n" \
  https://api.abhijeetrajput.life/

# Expected: HTTP 401  ← APIM responded on custom domain ✅
# If you get SSL error: cert not yet saved / Default SSL binding not On
```

---

## Step 4 — Private Application Gateway (WAF_v2, private frontend active, dummy public IP)

### Concept — Why AGIC is Not Used Here (Task 04 contrast)

Task 04 used **AGIC** (Application Gateway Ingress Controller) — a pod in `kube-system` that watches Kubernetes Ingress objects and auto-configures AGW routing rules.

This lab does **not** use AGIC, and that is intentional:

```
Task 04 pattern (AGIC):
  Dev writes ingress.yaml
  → AGIC pod reads it
  → AGIC calls Azure API → updates AGW backend pools + routing rules automatically
  → AGW routes directly to pod IPs (Azure CNI) or Internal LB (Overlay CNI)

Task 10 pattern (APIM + static AGW):
  APIM policy sets backend → http://10.0.3.4 (AGW private IP)
  AGW backend pool is statically set to ILB 10.0.1.50
  No AGIC — routing is controlled by APIM policies, not K8s Ingress objects

Why not AGIC here:
  1. APIM is the API gateway — it owns routing decisions (JWT, rate limit,
     path rewriting, backend selection). AGIC would add a second routing layer
     that conflicts with APIM's backend URL control.
  2. AGW here is a WAF hop, not the primary ingress. Its job is to inspect
     traffic from APIM and forward to ILB — not to make routing decisions.
  3. AGIC requires the AGW to be the public entry point. Here the public
     entry point is APIM — AGW has a dummy public IP that is never used.

When to use AGIC vs APIM+static AGW:
  AGIC        → AKS-native routing, no API management layer, dev-controlled ingress
  APIM+AGW    → Enterprise API gateway with policies, multi-service routing at APIM layer
```

Deploy **after** APIM is up. AGW private frontend IP must be known (use `10.0.3.4`).

> **WAF_v2 is required for production** (path-based routing across microservices + OWASP rules). Azure mandates a public IP on WAF_v2 / Standard_v2 SKUs — create a dummy one that sits unused. The NSG on `snet-agw` blocks all internet inbound so the public IP is effectively dead-facing.

### 4.0 Create dummy public IP for AGW (required by WAF_v2)

```bash
az network public-ip create \
  --name pip-agw-myapp-priv \
  --resource-group rg-myapp \
  --location southindia \
  --sku Standard \
  --allocation-method Static
# No --dns-name needed — this IP will never be used for DNS
```

### 4.1 Create AGW with WAF_v2 + private frontend active

**Portal:** `Application Gateway` → `Create`

| Tab | Field | Value |
|---|---|---|
| Basics | Name | `agw-myapp-priv` |
| Basics | Tier | **`WAF v2`** |
| Networking | VNet / Subnet | `vnet-myapp` / `snet-agw` |
| Frontends | Frontend IP type | **`Both`** ← WAF_v2 requires a public IP to exist |
| Frontends | Public IP | `pip-agw-myapp-priv` ← dummy; never used for DNS |
| Frontends | Private IP | `10.0.3.4` (static) |
| Backends | Pool name | `pool-aks` |
| Backends | Target type | **`IP address or FQDN`** |
| Backends | Target | `10.0.1.50` ← ILB IP (do NOT use VMSS — see warning below) |
| Configuration | Rule name | `rule-apim-to-aks` |
| Configuration | Rule priority | `100` |
| Configuration | Listener | `listener-http` · **HTTP** · port **80** · Frontend IP: **Private** |
| Configuration | Backend settings | `settings-aks` · HTTP · port 80 |
| Configuration | Routing rule type | `Basic` |
| WAF | Policy | Create new `apim3-waf` · Mode: **Detection** |

> **Rule name and priority** are required fields in the Portal routing rule wizard. Use `rule-apim-to-aks` / priority `100` — these become the AGW routing rule identifiers you'll reference when adding path-based rules per microservice later.

> ⚠️ **VMSS backend causes 502 — use ILB IP instead.**
> When you select `VMSS` as the backend target type in the Portal, Azure registers the
> VMSS node IP (e.g. `10.0.1.4`) directly in the backend pool. The AGW health probe hits
> the node at port 80 — but nothing is listening on port 80 on the raw node; httpbin only
> listens via the ILB. This causes `Unhealthy` backend and `502 Bad Gateway` from AGW.
>
> **Do not use VMSS as backend target.** Use `IP address or FQDN` and enter `10.0.1.50`
> (the ILB IP) directly. The VMSS wizard option is misleading here — ILB is the correct
> target for AKS services.
>
> If you already created AGW with VMSS target, fix it:
> ```bash
> az network application-gateway address-pool update \
>   --resource-group rg-myapp \
>   --gateway-name agw-myapp-priv \
>   --name pool-aks \
>   --servers 10.0.1.50
> ```
> Then verify backend health:
> ```bash
> az network application-gateway show-backend-health \
>   --resource-group rg-myapp \
>   --name agw-myapp-priv \
>   --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].{address:address, health:health}" \
>   -o table
> # Expected: 10.0.1.50  Healthy
> ```

> **WAF Detection vs Prevention:** Start in Detection mode — WAF logs rule matches but
> does not block. Switch to Prevention after reviewing logs and tuning exclusions.
> Premature Prevention mode will cause mysterious 403s from OWASP false positives.

**CLI (WAF_v2 + private frontend + ILB backend):**
```bash
# Create WAF policy
az network application-gateway waf-policy create \
  --resource-group rg-myapp \
  --name apim3-waf \
  --location southindia

# Create AGW — WAF_v2, private frontend 10.0.3.4, dummy public pip, ILB backend
az network application-gateway create \
  --resource-group rg-myapp \
  --name agw-myapp-priv \
  --location southindia \
  --sku WAF_v2 \
  --capacity 2 \
  --vnet-name vnet-myapp \
  --subnet snet-agw \
  --public-ip-address pip-agw-myapp-priv \
  --private-ip-address 10.0.3.4 \
  --servers 10.0.1.50 \
  --frontend-port 80 \
  --http-settings-port 80 \
  --http-settings-protocol Http \
  --routing-rule-type Basic \
  --waf-policy apim3-waf
```

### 4.2 Path-based routing `/orders/*` (optional, match APIM suffix)

**Portal:** `Rules` → Path-based → paths `/orders/*` → `pool-aks`

Or accept default rule forwarding all paths to httpbin (httpbin ignores prefix if APIM strips correctly).

### 4.3 Health probe → ILB

| Field | Value |
|---|---|
| Name | `probe-aks` |
| Protocol | `HTTP` |
| Pick host name from backend settings | `No` |
| Host | `10.0.1.50` |
| Pick port from backend settings | `Yes` |
| Path | `/get` |
| Interval (seconds) | `30` |
| Timeout (seconds) | `30` |
| Unhealthy threshold | `3` |
| Use probe matching conditions | `No` |
| Backend settings | `settings-aks` ← select from dropdown |

> **Why `Host = 10.0.1.50` manually:** "Pick host name from backend settings" is `No` here,
> so Azure won't auto-fill the host. Enter the ILB IP directly. If you switch to `Yes`,
> the Host field disappears and AGW pulls the host from `settings-aks` automatically —
> either works for this lab.

Click **Test** to verify the probe gets a 200 from httpbin before saving.

### 4.4 Confirm WAF policy is attached

**Portal:** `agw-myapp-priv` → **Web application firewall** → should show `apim3-waf` in Detection mode.

```bash
az network application-gateway show \
  --resource-group rg-myapp \
  --name agw-myapp-priv \
  --query "firewallPolicy.id" -o tsv
# Expected: .../apim3-waf

# Confirm mode is Detection (not Prevention yet)
az network application-gateway waf-policy show \
  --resource-group rg-myapp \
  --name apim3-waf \
  --query "policySettings.mode" -o tsv
# Expected: Detection
```

---

## Step 8 — PostgreSQL Private Link (from Task 06)

### Why PostgreSQL here

FinTrack's Orders API needs a database. The `httpbin` pod is a placeholder — in a real deployment, the orders-service pod would query PostgreSQL for order records. This step adds the database layer with private access only, consistent with the private-everything architecture of this lab.

```
Full request path after this step:

  Client → APIM (public) → AGW private (10.0.3.4) → ILB (10.0.1.50)
    → orders-service pod → pg-task10.postgres.database.azure.com
                               → Private DNS Zone → 10.0.4.x
                               → PostgreSQL Flexible Server (no public IP)
```

> `subnet-postgres` (10.10.4.0/24 in foundation VNet) is a different VNet from `vnet-myapp`.
> For this lab, PostgreSQL goes into `vnet-myapp`. We use a new `/24` block: `10.0.4.0/24`.

### Step 8.1 — Create Delegated Subnet for PostgreSQL

```bash
# Add subnet-postgres to vnet-myapp
az network vnet subnet create \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name snet-postgres \
  --address-prefixes 10.0.4.0/24 \
  --delegations Microsoft.DBforPostgreSQL/flexibleServers

# Verify delegation
az network vnet subnet show \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name snet-postgres \
  --query "delegations[].serviceName" -o tsv
# Expected: Microsoft.DBforPostgreSQL/flexibleServers
```

> ⚠️ **Critical rules — violating any causes PostgreSQL provisioning to FAIL:**
> - Do NOT attach NSG to snet-postgres
> - Do NOT attach Route Table (UDR) to snet-postgres
> - Do NOT enable private subnet flag on snet-postgres
> - Delegation MUST exist before server creation

### Step 8.2 — Create PostgreSQL Flexible Server

**Portal:**
```
Search "Azure Database for PostgreSQL flexible servers" → + Create

── Basics ────────────────────────────────────────────
   Resource group       → rg-myapp
   Server name          → pg-task10
   Region               → South India
   PostgreSQL version   → 16
   Workload type        → Development

   Compute + storage → Configure:
     Tier               → Burstable
     Size               → Standard_B1ms (1 vCore, 2 GiB)
     Storage            → 32 GiB
     HA                 → Disabled
     Geo-redundant backup → Disabled

   Admin username       → pgadmin
   Password             → PgAdmin@Task10!

── Networking ────────────────────────────────────────
   Connectivity method  → Private access (VNet Integration)  ← KEY
   Virtual network      → vnet-myapp
   Subnet               → snet-postgres
   Private DNS Zone     → Create new
                          (auto: pg-task10.private.postgres.database.azure.com)

→ Review + Create → Create
⏳ Takes 5–7 minutes
```

**CLI:**
```bash
PG_NAME="pg-task10"

az postgres flexible-server create \
  --resource-group $RESOURCE_GROUP \
  --name $PG_NAME \
  --location $LOCATION \
  --admin-user pgadmin \
  --admin-password 'PgAdmin@Task10!' \
  --sku-name Standard_B1ms \
  --tier Burstable \
  --storage-size 32 \
  --version 16 \
  --vnet $VNET_NAME \
  --subnet snet-postgres \
  --private-dns-zone "${PG_NAME}.private.postgres.database.azure.com" \
  --yes
```

### Step 8.3 — Verify Private DNS Zone

```bash
# DNS zone should be auto-created
az network private-dns zone show \
  --resource-group $RESOURCE_GROUP \
  --name "${PG_NAME}.private.postgres.database.azure.com" \
  --query name -o tsv

# VNet link must exist
az network private-dns link vnet list \
  --resource-group $RESOURCE_GROUP \
  --zone-name "${PG_NAME}.private.postgres.database.azure.com" \
  --query "[].{Name:name, State:provisioningState}" -o table
# Expected: Succeeded

# If VNet link is missing:
az network private-dns link vnet create \
  --resource-group $RESOURCE_GROUP \
  --zone-name "${PG_NAME}.private.postgres.database.azure.com" \
  --name link-vnet-myapp \
  --virtual-network $VNET_NAME \
  --registration-enabled false
```

### Step 8.4 — Test DNS Resolution from Pod

```bash
# Spin up temp pod
kubectl run psql-client \
  --image=postgres:16 \
  --restart=Never \
  --rm -it \
  -- bash

# Inside pod — DNS check
nslookup pg-task10.postgres.database.azure.com
# MUST return 10.0.4.x (private IP)
# If returns public IP → Private DNS Zone not linked to vnet-myapp → fix link above

# Connect and create app objects
psql -h pg-task10.postgres.database.azure.com -U pgadmin -d postgres
# password: PgAdmin@Task10!

CREATE DATABASE ordersdb;
CREATE USER ordersuser WITH PASSWORD 'Orders@Task10!';
GRANT ALL PRIVILEGES ON DATABASE ordersdb TO ordersuser;
\q
exit
```

### Step 8.5 — Store Credentials as Kubernetes Secret

```bash
kubectl create secret generic pg-orders-credentials \
  --from-literal=POSTGRES_HOST=pg-task10.postgres.database.azure.com \
  --from-literal=POSTGRES_PORT=5432 \
  --from-literal=POSTGRES_DB=ordersdb \
  --from-literal=POSTGRES_USER=ordersuser \
  --from-literal=POSTGRES_PASSWORD='Orders@Task10!' \
  --from-literal=DATABASE_URL="postgresql://ordersuser:Orders@Task10!@pg-task10.postgres.database.azure.com:5432/ordersdb?sslmode=require"

kubectl get secret pg-orders-credentials
```

### Step 8.6 — Verify No Public Access

```bash
# From your laptop — must fail
psql -h pg-task10.postgres.database.azure.com -U pgadmin -d postgres
# Expected: connection timeout ✅ (public access disabled)
```

### Step 8.7 — NetworkPolicy (Restrict DB Access to Orders Pods Only)

```yaml
# netpol-orders-db.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-postgres-from-orders
  namespace: orders
spec:
  podSelector:
    matchLabels:
      app: orders-service
  policyTypes:
  - Egress
  egress:
  - ports:
    - port: 5432
      protocol: TCP
```

```bash
kubectl apply -f netpol-orders-db.yaml
# Only pods with app=orders-service in orders namespace can reach port 5432
# httpbin pods, monitoring sidecars — all blocked
```

### PostgreSQL vs ACR/KV Private Endpoints — Key Difference

| | PostgreSQL Flexible Server | ACR / Key Vault (if added) |
|---|---|---|
| Method | VNet Integration (subnet delegation) | Private Endpoint (NIC in subnet) |
| Subnet | Dedicated delegated — only PG allowed | Shared — multiple PEs can coexist |
| DNS zone | `pg-task10.private.postgres.database.azure.com` | `privatelink.azurecr.io` etc. |
| Public disable | Permanent — set at creation, cannot change | Can toggle anytime |
| NSG/UDR | ❌ Cannot attach — breaks provisioning | ✅ Optional |

---

## Step 9 — Workload Identity + Key Vault Secret from Pod

### Concept

In Step 8 we stored the PostgreSQL password in a K8s Secret. K8s Secrets are base64-encoded, not encrypted at rest by default, and anyone with cluster access can read them. Workload Identity solves this: the pod fetches the secret directly from Key Vault using a Managed Identity token — no password ever touches the cluster.

```
Without Workload Identity (current state after Step 8):
  Pod reads K8s Secret → gets PG password as env var
  Risk: secret visible to anyone with kubectl get secret
       secret stored in etcd (base64, not encrypted unless KMS enabled)

With Workload Identity (after this step):
  Pod → OIDC token → Azure AD → Managed Identity token
  Pod → Key Vault API → fetches pg-password secret
  No password in K8s Secret, no password in pod spec

Token exchange flow:
  1. AKS OIDC issuer signs a K8s ServiceAccount token
  2. Pod SDK sends that token to Azure AD
  3. Azure AD validates: issuer URL matches federated credential?
                        subject (namespace/serviceaccount) matches?
  4. Returns short-lived Azure access token for Managed Identity
  5. Pod uses that token to call Key Vault — auto-refreshed
```

### Step 9.1 — Verify AKS Has OIDC Issuer Enabled

```bash
# Check if OIDC issuer is enabled
az aks show \
  --resource-group $RESOURCE_GROUP \
  --name aks-myapp \
  --query "oidcIssuerProfile" -o json
# If enabled: {"enabled": true, "issuerUrl": "https://..."}
# If not enabled:
az aks update \
  --resource-group $RESOURCE_GROUP \
  --name aks-myapp \
  --enable-oidc-issuer \
  --enable-workload-identity
```

### Step 9.2 — Create Key Vault

```bash
KV_NAME="kv-apim3-lab"

az keyvault create \
  --resource-group $RESOURCE_GROUP \
  --name $KV_NAME \
  --location $LOCATION \
  --sku standard \
  --enable-rbac-authorization true

# Store the PostgreSQL password as a secret
az keyvault secret set \
  --vault-name $KV_NAME \
  --name pg-orders-password \
  --value 'Orders@Task10!'

# Verify
az keyvault secret show \
  --vault-name $KV_NAME \
  --name pg-orders-password \
  --query value -o tsv
# Expected: Orders@Task10!
```

> **Key Vault stays public here** (no private endpoint) for simplicity.
> In production, add a private endpoint to `snet-aks` and disable public access.
> The APIM managed identity (from Step 2.1) can also use this same Key Vault
> for TLS cert auto-rotation via Key Vault certificate reference.

### Step 9.3 — Create Managed Identity

```bash
WI_NAME="wi-apim3"

az identity create \
  --resource-group $RESOURCE_GROUP \
  --name $WI_NAME \
  --location $LOCATION

WI_CLIENT_ID=$(az identity show \
  --resource-group $RESOURCE_GROUP \
  --name $WI_NAME \
  --query clientId -o tsv)

WI_PRINCIPAL_ID=$(az identity show \
  --resource-group $RESOURCE_GROUP \
  --name $WI_NAME \
  --query principalId -o tsv)

echo "Client ID   : $WI_CLIENT_ID"
echo "Principal ID: $WI_PRINCIPAL_ID"

# Wait for Entra ID replication
sleep 60
```

### Step 9.4 — Assign Key Vault Secrets User Role

```bash
KV_SCOPE=$(az keyvault show \
  --name $KV_NAME \
  --resource-group $RESOURCE_GROUP \
  --query id -o tsv)

az role assignment create \
  --assignee-object-id $WI_PRINCIPAL_ID \
  --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" \
  --scope $KV_SCOPE
```

**Portal:**
```
Key Vaults → kv-apim3-lab → Access control (IAM) → + Add role assignment
  Role    → Key Vault Secrets User
  Members → Managed identity → wi-apim3
→ Review + assign

⚠️ Key Vault permission model must be Azure RBAC (not Vault access policy)
   Check: Key Vaults → kv-apim3-lab → Settings → Access configuration
   Must show: Azure role-based access control
```

### Step 9.5 — Create Federated Credential

```bash
# Get OIDC issuer URL
AKS_OIDC_ISSUER=$(az aks show \
  --resource-group $RESOURCE_GROUP \
  --name aks-myapp \
  --query "oidcIssuerProfile.issuerUrl" -o tsv)

echo "OIDC Issuer: $AKS_OIDC_ISSUER"

# Create federated credential linking K8s ServiceAccount → Managed Identity
az identity federated-credential create \
  --name apim3-federated-cred \
  --identity-name $WI_NAME \
  --resource-group $RESOURCE_GROUP \
  --issuer $AKS_OIDC_ISSUER \
  --subject "system:serviceaccount:orders:orders-sa" \
  --audience api://AzureADTokenExchange
```

**Portal:**
```
Managed Identities → wi-apim3 → Settings → Federated credentials → + Add credential

  Scenario        → Kubernetes accessing Azure resources
  Cluster Issuer URL → paste OIDC URL from above
  Namespace       → orders
  Service account → orders-sa
  Name            → apim3-federated-cred
  Audience        → api://AzureADTokenExchange

→ Add

⚠️ Namespace + ServiceAccount MUST exactly match what you create in Step 9.6
   Mismatch = silent 401 from Key Vault
```

### Step 9.6 — Create Kubernetes ServiceAccount

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: orders-sa
  namespace: orders
  annotations:
    azure.workload.identity/client-id: "${WI_CLIENT_ID}"
  labels:
    azure.workload.identity/use: "true"
EOF
```

### Step 9.7 — Deploy Pod That Reads Key Vault Secret

```yaml
# kv-reader-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: kv-reader
  namespace: orders
  labels:
    azure.workload.identity/use: "true"   # ← webhook injects OIDC token
spec:
  serviceAccountName: orders-sa
  containers:
  - name: reader
    image: mcr.microsoft.com/azure-cli:latest
    command: ["sleep", "3600"]
```

```bash
kubectl apply -f kv-reader-pod.yaml
kubectl get pod kv-reader -n orders   # wait for Running

# Read the pg-orders-password secret — no credentials in pod spec!
kubectl exec -it kv-reader -n orders -- \
  az keyvault secret show \
  --vault-name $KV_NAME \
  --name pg-orders-password \
  --query value -o tsv

# Expected: Orders@Task10! ✅
# No passwords in env vars, no K8s Secret, no hardcoded credentials
```

### How Workload Identity Works Internally

```
Webhook injects into pod (when azure.workload.identity/use: "true"):
  AZURE_CLIENT_ID             = wi-apim3 client ID
  AZURE_TENANT_ID             = your Azure tenant
  AZURE_FEDERATED_TOKEN_FILE  = /var/run/secrets/azure/tokens/azure-identity-token

At runtime:
  Pod SDK reads AZURE_FEDERATED_TOKEN_FILE (K8s-signed token)
  → Sends to Azure AD with client_id + audience
  → Azure AD validates: issuer URL? subject = orders/orders-sa? ✅
  → Returns short-lived Azure access token for wi-apim3
  → Token used to call Key Vault / Blob / any Azure resource
  → Auto-refreshed — no expiry management needed

What is NOT in your cluster:
  ❌ No client secrets
  ❌ No storage account keys
  ❌ No base64-encoded passwords in K8s Secrets
  ✅ Just a ServiceAccount + one label
```

---

## Step 10 — Blob Storage Access from Pod (Workload Identity)

### Why Blob Storage here

FinTrack's orders service generates PDF receipts and stores them in blob storage. In production, the pod uses Workload Identity to write receipts — no storage account keys in the pod spec or K8s Secrets. The same `orders-sa` ServiceAccount and `wi-apim3` Managed Identity from Step 9 are reused.

```
Orders pod → Workload Identity token → Azure AD
              → Storage Blob Data Contributor role on orders-receipts container
              → Upload/download blobs
              → No account keys anywhere
```

### Step 10.1 — Create Storage Account and Container

```bash
STORAGE_NAME="stapim3lab"    # globally unique, lowercase, no hyphens

az storage account create \
  --resource-group $RESOURCE_GROUP \
  --name $STORAGE_NAME \
  --location $LOCATION \
  --sku Standard_LRS \
  --kind StorageV2 \
  --allow-blob-public-access false \
  --min-tls-version TLS1_2

az storage container create \
  --account-name $STORAGE_NAME \
  --name orders-receipts \
  --auth-mode login

# Upload a test receipt file
echo '{"order_id": "ORD-001", "amount": 4999, "status": "paid"}' > receipt-001.json

az storage blob upload \
  --account-name $STORAGE_NAME \
  --container-name orders-receipts \
  --name receipt-001.json \
  --file receipt-001.json \
  --auth-mode login

echo "Test file uploaded ✅"
```

### Step 10.2 — Assign Blob Role to Managed Identity

```bash
STORAGE_SCOPE=$(az storage account show \
  --name $STORAGE_NAME \
  --resource-group $RESOURCE_GROUP \
  --query id -o tsv)

# Scope to the specific container — least-privilege
az role assignment create \
  --assignee-object-id $WI_PRINCIPAL_ID \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope "$STORAGE_SCOPE/blobServices/default/containers/orders-receipts"
```

**Portal:**
```
Storage accounts → stapim3lab → Containers → orders-receipts
→ Access control (IAM) → + Add role assignment
   Role    → Storage Blob Data Contributor
   Members → Managed identity → wi-apim3
→ Review + assign

⚠️ Must use Storage Blob Data * roles (data plane)
   Assigning Contributor (management plane) does NOT grant blob read/write
```

### Step 10.3 — Deploy Pod That Reads and Writes Blobs

```yaml
# blob-orders-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: blob-orders
  namespace: orders
  labels:
    azure.workload.identity/use: "true"
spec:
  serviceAccountName: orders-sa   # same SA as Step 9 — already has federated credential
  containers:
  - name: orders
    image: mcr.microsoft.com/azure-cli:latest
    command: ["sleep", "3600"]
    env:
    - name: STORAGE_ACCOUNT
      value: "stapim3lab"
    - name: CONTAINER_NAME
      value: "orders-receipts"
```

```bash
kubectl apply -f blob-orders-pod.yaml
kubectl get pod blob-orders -n orders   # wait for Running

# Download the receipt — uses Workload Identity token, not account key
kubectl exec -it blob-orders -n orders -- \
  az storage blob download \
  --account-name stapim3lab \
  --container-name orders-receipts \
  --name receipt-001.json \
  --file /tmp/receipt-001.json \
  --auth-mode login

kubectl exec -it blob-orders -n orders -- cat /tmp/receipt-001.json
# Expected: {"order_id": "ORD-001", "amount": 4999, "status": "paid"} ✅

# Upload a new receipt from the pod
kubectl exec -it blob-orders -n orders -- bash -c '
  echo "{\"order_id\": \"ORD-002\", \"amount\": 1299, \"status\": \"paid\"}" > /tmp/receipt-002.json
  az storage blob upload \
    --account-name stapim3lab \
    --container-name orders-receipts \
    --name receipt-002.json \
    --file /tmp/receipt-002.json \
    --auth-mode login
  echo "Uploaded ✅"
'
```

### Step 10.4 — Verify from Laptop (via VPN)

```bash
# From your laptop — must be on VPN
az storage blob list \
  --account-name stapim3lab \
  --container-name orders-receipts \
  --auth-mode login \
  --query "[].name" -o tsv
# Expected: receipt-001.json, receipt-002.json ✅
```

### Production Pattern — Azure SDK in App Code

```python
# Python orders service
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient
from azure.keyvault.secrets import SecretClient

credential = DefaultAzureCredential()  # picks up Workload Identity env vars in pod

# Read DB password from Key Vault
kv_client = SecretClient(
    vault_url="https://kv-apim3-lab.vault.azure.net",
    credential=credential
)
pg_password = kv_client.get_secret("pg-orders-password").value

# Upload receipt to blob
blob_client = BlobServiceClient(
    account_url="https://stapim3lab.blob.core.windows.net",
    credential=credential
)
container = blob_client.get_container_client("orders-receipts")
container.upload_blob(name=f"receipt-{order_id}.json", data=receipt_json)
```

---

## Step 5 — APIM API, operations, policies (backend = private AGW)

### 5.1 Create Orders API

**Portal:** `apim-myapp-pub` → `APIs` → `HTTP`

| Field | Value |
|---|---|
| Display name | `Orders API` |
| Name | `orders-api` (auto-fills) |
| Description | `httpbin-based orders service via private AGW` |
| Web service URL | `http://10.0.3.4` |
| URL scheme | `HTTPS` |
| API URL suffix | `orders` |
| Gateways | `Managed` ✔️ |
| Subscription required | ✔️ on |
| User authorization | `None` |

> **Base URL** confirms as `https://api.abhijeetrajput.life/orders` — custom domain is active.
> **Products** — leave blank for now. For production, create a product (e.g. `internal-services`) and associate APIs to it.
> **URL scheme `HTTPS` not `HTTP(S)`** — clients always hit APIM over HTTPS; `HTTP(S)` is too permissive.

Hit **Create**, then add operations.

### 5.2 Add operations

**Portal:** `Orders API` → `Design` → `+ Add operation`

Add each operation and hit **Save** before clicking **+ Add operation** again:

**Operation 1 — Get**

| Field | Value |
|---|---|
| Display name | `Get` |
| Name | `get` (auto-fills) |
| URL method | `GET` |
| URL path | `/get` |

**Operation 2 — Post**

| Field | Value |
|---|---|
| Display name | `Post` |
| Name | `post` (auto-fills) |
| URL method | `POST` |
| URL path | `/post` |

**Operation 3 — Headers**

| Field | Value |
|---|---|
| Display name | `Headers` |
| Name | `headers` (auto-fills) |
| URL method | `GET` |
| URL path | `/headers` |

**Operation 4 — IP**

| Field | Value |
|---|---|
| Display name | `IP` |
| Name | `ip` (auto-fills) |
| URL method | `GET` |
| URL path | `/ip` |

> Leave Description, Tags, and Template parameters blank for all operations.

Full URLs after adding:

| Operation | Full URL |
|---|---|
| Get | `https://api.abhijeetrajput.life/orders/get` |
| Post | `https://api.abhijeetrajput.life/orders/post` |
| Headers | `https://api.abhijeetrajput.life/orders/headers` |
| IP | `https://api.abhijeetrajput.life/orders/ip` |

### 5.3 Inbound policies

**Portal:** `Orders API` → `Design` → `All operations` → click `</>` next to **Inbound processing**

This opens the full policy editor showing all four sections. Paste the entire block below and hit **Save**.

> ⚠️ **CORS cannot be added via the Portal policy editor** — the Developer tier rejects `<cors>` at every scope (All operations, API-level outbound, scoped outbound editor) with `Policy is not allowed in this section`. Do not attempt to add it through the UI. Not required for any test scenario.

> ⚠️ **Replace `{tenant-id}` and `{app-id}`** before saving:
> ```bash
> az account show --query tenantId -o tsv   # tenant-id
> az ad app list --display-name "orders-api" --query "[0].appId" -o tsv  # app-id
> ```
> APIM fetches the OpenID config URL at save time — leaving placeholders causes an immediate fetch error.
>
> ⚠️ **`api://orders` identifier URI may be blocked by tenant policy.** Use `api://{app-id}` format instead and match the `<value>` and token scope accordingly. Also ensure a service principal exists: `az ad sp create --id {app-id}`.

> ⚠️ **Use the full `<policies>` block editor only** — the scoped editors (Outbound processing box `</>`, Backend box `</>`) accept only a single root element without section wrappers and will reject `<base />` + any policy together. Always use the Inbound processing `</>` which opens the full editor.

```xml
<policies>
  <inbound>
    <base />
    <validate-jwt header-name="Authorization"
                  failed-validation-httpcode="401"
                  failed-validation-error-message="Unauthorized">
      <openid-config url="https://login.microsoftonline.com/{tenant-id}/.well-known/openid-configuration" />
      <required-claims>
        <claim name="aud">
          <value>api://orders</value>
        </claim>
      </required-claims>
    </validate-jwt>
    <rate-limit-by-key
      calls="200"
      renewal-period="60"
      counter-key="@(context.Subscription.Id)"
      remaining-calls-header-name="X-RateLimit-Remaining"
      retry-after-header-name="Retry-After" />
    <set-header name="X-Forwarded-For" exists-action="override">
      <value>@(context.Request.IpAddress)</value>
    </set-header>
    <set-header name="Authorization" exists-action="delete" />
    <set-backend-service base-url="http://10.0.3.4" />
  </inbound>
  <backend>
    <base />
  </backend>
  <outbound>
    <base />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>
```

**Verify save succeeded:** no red error banner, policy tiles appear under Inbound processing showing `validate-j...` and `rate-limi...`.

---

## Step 6 — DNS on Hostinger (point to **APIM public IP**)

### 6.1 Get APIM public IP

```bash
az apim show \
  --resource-group rg-myapp \
  --name apim-myapp-pub \
  --query "publicIpAddresses[0]" -o tsv
```

### 6.2 A record in Hostinger

| Type | Name | Points to | TTL |
|---|---|---|---|
| `A` | `api` | `<APIM public IP>` | `300` |

```bash
dig api.abhijeetrajput.life +short
# Must return APIM public IP (NOT AGW — AGW has no public IP)
```

### 6.3 No Private DNS override for public clients

Unlike APIM 2, **do not** point private DNS `api` → `10.0.2.4` for this lab if you want laptop tests to hit public APIM. Optional: private DNS `agw.internal` → `10.0.3.4` only for debugging from jump box.

| Who is asking | Resolves to |
|---|---|
| Internet / laptop | APIM **public** IP (Hostinger) |
| APIM → AGW | `http://10.0.3.4` (policy backend URL) |
| AGW → AKS | `http://10.0.1.50` |

---

## Step 7 — Test scenarios

```bash
TOKEN=$(curl -s -X POST \
  "https://login.microsoftonline.com/cb59a30a-1a3e-49f5-b0fc-97e189c1c579/oauth2/v2.0/token" \
  -d "grant_type=client_credentials" \
  -d "client_id=07448375-836c-4a51-8a37-cd6ef499f341" \
  -d "client_secret=$SECRET" \
  -d "scope=api://07448375-836c-4a51-8a37-cd6ef499f341/.default" \
  | jq -r .access_token)
```

### Scenario 1 — No JWT → 401

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  https://api.abhijeetrajput.life/orders/get
# Expected: HTTP 401
```

### Scenario 2 — Bad JWT → 401

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  -H "Authorization: Bearer fake.token" \
  -H "Ocp-Apim-Subscription-Key: b591cfa8ce7e426bb2c9c6e201941183" \
  https://api.abhijeetrajput.life/orders/get
# Expected: HTTP 401
```

### Scenario 3 — Happy path → 200

```bash
curl -s -w "\nHTTP %{http_code}\n" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Ocp-Apim-Subscription-Key: b591cfa8ce7e426bb2c9c6e201941183" \
  https://api.abhijeetrajput.life/orders/get
# Expected: HTTP 200 + httpbin JSON
# X-Appgw-Trace-Id present — confirms traffic went through AGW
# origin shows 10.0.2.x — confirms APIM private IP forwarded the request
```

### Scenario 4 — Authorization header stripped at pod

```bash
curl -s \
  -H "Authorization: Bearer $TOKEN" \
  -H "Ocp-Apim-Subscription-Key: b591cfa8ce7e426bb2c9c6e201941183" \
  https://api.abhijeetrajput.life/orders/headers | jq .headers
# Expected: no Authorization key in response
```

### Scenario 5 — Rate limit → 429

```bash
for i in $(seq 1 210); do
  curl -s -o /dev/null -w "Request $i: %{http_code}\n" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Ocp-Apim-Subscription-Key: b591cfa8ce7e426bb2c9c6e201941183" \
    https://api.abhijeetrajput.life/orders/get
done
# Requests 201+: HTTP 429
```

### Scenario 6 — Private AGW unreachable from internet

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" --connect-timeout 5 \
  http://10.0.3.4/orders/get
# Expected: timeout or connection refused — AGW has no public exposure
```

---

```
curl → APIM (104.211.219.189) → AGW (10.0.3.4) → ILB (10.0.1.50) → httpbin pod → 200

Pod logs (gunicorn access logging enabled via --access-logfile -):
  10.0.1.4 - - [31/May/2026] "GET /get HTTP/1.1" 200 — source is AKS node (ILB SNAT)
```

## All scenarios at a glance

| # | Scenario | Handled by | Expected | Result |
|---|---|---|---|---|
| 1 | No JWT | APIM | 401 | ✅ 401 |
| 2 | Bad JWT | APIM | 401 | ✅ 401 |
| 3 | Happy path | full chain | 200 | ✅ 200 |
| 4 | Auth header stripped | APIM | absent at pod | ✅ no Authorization in headers |
| 5 | Rate limit | APIM | 429 | ⚠️ see note |
| 6 | Direct private AGW from internet | network | timeout | ✅ HTTP 000 (no route) |

> **Scenario 4 note:** `Authorization` header correctly absent from httpbin response. `Ocp-Apim-Subscription-Key` is still present — only the `Authorization` header was targeted by the `delete` policy, which is correct.

> **Scenario 5 note:** Rate limit test interrupted at request 7 (`^C`). The policy is set to 200 calls/60s — to properly trigger 429, let the loop run past 200. Token expiry will cause 401 before 429 if the loop runs too long; refresh token before running the full 210-request loop.

---

## What tasks 04, 05, 06, 09 are covered by this lab

| Task | What it covers | Where in this lab | Gap |
|---|---|---|---|
| Task 04 — AGIC + SSL | SSL/TLS with Let's Encrypt, custom domain | Step 3 (certbot, PFX, APIM custom domain) | AGIC not used — see concept in Step 4. SSL fully covered. |
| Task 04 — AGIC concept | Why AGW does/doesn't need AGIC | Step 4 concept note | Hands-on AGIC skipped — APIM owns routing here |
| Task 05 — Entra ID RBAC | AKS cluster-level user/group/namespace access | Step 1a | ✅ Fully covered |
| Task 05 — Entra ID JWT | API-level token validation | Step 5.3 (validate-jwt policy) | ✅ Fully covered |
| Task 06 — PostgreSQL Private Link | Private DB, VNet integration, DNS, K8s Secret, NetworkPolicy | Step 8 | ✅ Fully covered |
| Task 09 Phase 2 — OpenVPN | VPN VM setup, IP forwarding, NSG, angristan script, .ovpn | Step 0.3 | ✅ Fully covered |
| Task 09 Phase 7 — Workload Identity | Managed Identity, OIDC, federated credential, KV secret from pod | Step 9 | ✅ Fully covered |
| Task 09 Phase 8 — Blob Storage | Storage account, container, pod reads/writes via WI | Step 10 | ✅ Fully covered |

---

## Summary

| Hop | Protocol | From | To | Port |
|---|---|---|---|---|
| Client → APIM | HTTPS | Internet | APIM public IP | 443 |
| APIM → AGW | HTTP | `10.0.2.x` | `10.0.3.4` | 80 |
| AGW → ILB | HTTP | `10.0.3.x` | `10.0.1.50` | 80 |
| ILB → pod | HTTP | ILB | Pod | 80 |

| Component | DNS / routing |
|---|---|
| APIM | `api.abhijeetrajput.life` → **public IP** (Hostinger) |
| AGW | **No public DNS** — `10.0.3.4` only |
| AKS ILB | `10.0.1.50` — no public DNS |

---

## Compare with APIM 2

| Topic | APIM 2 | APIM 3 (this lab) |
|---|---|---|
| Internet entry | Public AGW | **Public APIM** |
| Middle hop | Private APIM | **Private AGW** |
| DNS A record | AGW public IP | **APIM public IP** |
| WAF | **WAF_v2** on AGW (before APIM) | **WAF_v2** on AGW (after APIM, Detection mode) |
| Typical production use | ✅ Common | ✅ Valid for microservices path routing |

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Portal error: Public IP must have FQDN | Selected AKS-managed IP or IP without DNS label | Create `pip-apim-myapp-pub` with `--dns-name` (Step 2.0) |
| Portal blocks AGW creation — NSG blocks 65200-65535 | `GatewayManager` infra ports denied on `nsg-agw` | Add `allow-agw-infra` rule: priority 105, source `GatewayManager`, ports 65200-65535, inbound allow |
| Portal error: WAF_v2 / Standard_v2 requires public IP | Azure SKU hard requirement | Create dummy `pip-agw-myapp-priv` (Standard Static, no DNS label); select `Both` for frontend type in Portal |
| certbot fails / TXT not found | Propagation not complete | Run `dig TXT _acme-challenge.api...` and wait until token appears before pressing Enter |
| SSL error on custom domain | PFX not uploaded / Default SSL binding Off | Re-upload PFX in Step 3.2; tick Default SSL binding On |
| `dig api` shows wrong IP | Hostinger still points to old AGW IP | Update A → APIM public IP |
| 502 from APIM | APIM cannot reach AGW | NSG `10.0.2.0/24` → `10.0.3.0/24:80`; verify `10.0.3.4` |
| 502 from AGW — `Microsoft-Azure-Application-Gateway/v2` | VMSS node IP in backend pool instead of ILB | Remove VMSS target: `az network application-gateway address-pool update --servers 10.0.1.50`; verify health shows `10.0.1.50 Healthy` |
| 502 from AGW — both ILB and node IP in pool | Portal VMSS wizard adds node IP alongside ILB | Same fix — update pool to `10.0.1.50` only |
| 404 on `/orders/get` | Wrong backend URL on APIM | `set-backend-service` = `http://10.0.3.4` |
| Works from jump box, not laptop | Private DNS overrides `api.*` inside VNet only | Expected; laptop uses Hostinger |
| Accidentally created WAF in Prevention mode | OWASP false positives blocking traffic | Switch `apim3-waf` to Detection mode; review diagnostics logs before enabling Prevention |
| Key Vault cert fetch fails | Managed identity not enabled on APIM | Enable system-assigned identity → re-assign Key Vault role |
| OpenVPN connects but cannot reach 10.0.x.x | IP forwarding not enabled on NIC | Portal: VM NIC → IP configurations → IP forwarding ON |
| OpenVPN connects but DNS does not resolve privatelink | Wrong DNS in .ovpn (not 168.63.129.16) | Re-run installer with Custom DNS 168.63.129.16; regenerate .ovpn |
| Workload Identity: 401 from Key Vault | Federated credential namespace/SA mismatch | Check `az identity federated-credential list` — subject must be `system:serviceaccount:orders:orders-sa` |
| Workload Identity: exec plugin error | kubelogin not installed or token cache stale | `sudo az aks install-cli`; `az login` again |
| Blob upload 403 | Assigned wrong role (Contributor not Blob Data Contributor) | Assign `Storage Blob Data Contributor` at container scope |
| `az storage blob` 403 with `--auth-mode login` | Role not propagated yet | Wait 1–2 minutes; role assignments propagate async |
| PostgreSQL DNS resolves to public IP from laptop via VPN | Azure DNS not set as VPN DNS | Re-run OpenVPN installer with Primary DNS 168.63.129.16 |

---

## Status: ✅ Lab complete — HTTP 200 end to end confirmed. Scenarios 1–4, 6 fully validated. Scenario 5 (rate limit) policy confirmed active; full 210-loop test pending.
