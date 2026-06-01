# APIM 3 — Phase-by-Phase Implementation

> **Source:** [readme.md](./readme.md) — this file is the hands-on execution checklist.
> The readme is the reference; this file is what you follow when actually building.

## Progress tracker

| Phase | What gets built | Status |
|---|---|---|
| 1 | Shell variables + pre-checks | ⬜ |
| 2 | NSG verification (nsg-agw, nsg-apim) | ⬜ |
| 3 | VPN VM (OpenVPN) | ⬜ |
| 4 | AKS — httpbin ILB + Entra ID K8s RBAC | ⬜ |
| 5 | APIM provisioning + TLS custom domain | ⬜ |
| 6 | Application Gateway (WAF_v2, private) | ⬜ |
| 7 | APIM API + policies + DNS | ⬜ |
| 8 | PostgreSQL Private Link | ⬜ |
| 9 | Workload Identity + Key Vault | ⬜ |
| 10 | Blob Storage via Workload Identity | ⬜ |
| 11 | End-to-end test scenarios | ⬜ |

Mark each phase ✅ when complete before moving to the next.

---

## Phase 1 — Shell Variables + Pre-checks

> Run this block at the start of **every session**. All later phases reference these variables.

```bash
az login

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
az account set --subscription $SUBSCRIPTION_ID

# Core
RESOURCE_GROUP="rg-myapp"
VNET_NAME="vnet-myapp"
LOCATION="southindia"

# Network
APIM_SUBNET="snet-apim"
AGW_SUBNET="snet-agw"
AKS_SUBNET="snet-aks"
PG_SUBNET="snet-postgres"

# Resource names
AKS_NAME="aks-myapp"
APIM_NAME="apim-myapp-pub"
AGW_NAME="agw-myapp-priv"
WAF_POLICY="apim3-waf"
VPN_VM_NAME="vpn-vm-apim3"
PG_NAME="pg-task10"
KV_NAME="kv-apim3-lab"
STORAGE_NAME="stapim3lab"
WI_NAME="wi-apim3"

# Public IPs
PIP_APIM="pip-apim-myapp-pub"
PIP_AGW="pip-agw-myapp-priv"
PIP_VPN="pip-vpn-apim3"

echo "RG       : $RESOURCE_GROUP"
echo "VNet     : $VNET_NAME"
echo "Location : $LOCATION"
echo "AKS      : $AKS_NAME"
echo "APIM     : $APIM_NAME"
```

### Pre-check: snet-apim must have no delegation

```bash
az network vnet subnet show \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name $APIM_SUBNET \
  --query "delegations" -o json
# Expected: []
# If NOT empty — remove it:
az network vnet subnet update \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name $APIM_SUBNET \
  --remove delegations
```

### Pre-check: required subnets exist

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

**Phase 1 complete?** ⬜ All variables set, pre-checks passed.

---

## Phase 2 — NSG Verification

### 2.1 Verify nsg-agw rules

```bash
az network nsg show \
  -g $RESOURCE_GROUP \
  -n nsg-agw \
  --query "securityRules[].{Name:name, Priority:priority, Access:access}" \
  -o table
# Must include: allow-apim-to-agw (100), allow-agw-infra (105),
#               Azure-health-probe (115), allow-vnet (120)
```

If any rule is missing, recreate it:

```bash
# allow-apim-to-agw — APIM subnet → AGW port 80
az network nsg rule create \
  --resource-group $RESOURCE_GROUP --nsg-name nsg-agw \
  --name allow-apim-to-agw --priority 100 --protocol Tcp --access Allow \
  --direction Inbound \
  --source-address-prefixes 10.0.2.0/24 \
  --destination-port-ranges 80

# allow-agw-infra — MANDATORY for WAF_v2, Azure control plane
az network nsg rule create \
  --resource-group $RESOURCE_GROUP --nsg-name nsg-agw \
  --name allow-agw-infra --priority 105 --protocol Tcp --access Allow \
  --direction Inbound \
  --source-address-prefixes GatewayManager \
  --destination-address-prefixes '*' \
  --destination-port-ranges 65200-65535

# Azure-health-probe — AGW health checks
az network nsg rule create \
  --resource-group $RESOURCE_GROUP --nsg-name nsg-agw \
  --name Azure-health-probe --priority 115 --protocol "*" --access Allow \
  --direction Inbound \
  --source-address-prefixes AzureLoadBalancer \
  --destination-port-ranges 6390

# allow-vnet — intra-VNet
az network nsg rule create \
  --resource-group $RESOURCE_GROUP --nsg-name nsg-agw \
  --name allow-vnet --priority 120 --protocol "*" --access Allow \
  --direction Inbound \
  --source-address-prefixes VirtualNetwork \
  --destination-port-ranges '*'

# Attach NSG to snet-agw
az network vnet subnet update \
  --resource-group $RESOURCE_GROUP --vnet-name $VNET_NAME \
  --name $AGW_SUBNET \
  --network-security-group nsg-agw
```

### 2.2 Verify/add nsg-apim APIM 3-specific rules

```bash
az network nsg show \
  -g $RESOURCE_GROUP \
  -n nsg-apim \
  --query "securityRules[].{Name:name, Priority:priority, Direction:direction}" \
  -o table
```

The following rules must be present. Add any that are missing:

```bash
# Inbound: public clients → APIM gateway (APIM 3 specific — internet hits APIM first)
az network nsg rule create \
  --resource-group $RESOURCE_GROUP --nsg-name nsg-apim \
  --name allow-internet-gateway --priority 130 --protocol Tcp --access Allow \
  --direction Inbound \
  --source-address-prefixes Internet \
  --destination-port-ranges 443

# Outbound: APIM → private AGW
az network nsg rule create \
  --resource-group $RESOURCE_GROUP --nsg-name nsg-apim \
  --name allow-apim-to-agw-out --priority 140 --protocol Tcp --access Allow \
  --direction Outbound \
  --destination-address-prefixes 10.0.3.0/24 \
  --destination-port-ranges 80
```

> ⚠️ Keep `allow-api-mgnmt`, `allow-vnet`, `Azure-health-probe`, and outbound
> Storage/Sql/KeyVault rules that were created in `common-resources.md`. Do not delete them.

**Phase 2 complete?** ⬜ Both NSGs have correct rules.

---

## Phase 3 — VPN VM (OpenVPN)

> Required to access private resources: AGW `10.0.3.4`, AKS ILB `10.0.1.50`,
> PostgreSQL `10.0.4.x`. Without VPN you can only reach APIM's public IP.

### 3.1 Create VM

**Portal:**
```
Virtual Machines → Create → Azure Virtual Machine

── Basics ──────────────────────────────────
   Resource Group    → rg-myapp
   VM Name           → vpn-vm-apim3
   Region            → South India
   Image             → Ubuntu Server 24.04 LTS - Gen2
   Size              → Standard_B2ts_v2
   Authentication    → Password
   Username          → azureuser
   Security type     → Trusted launch

── Networking ──────────────────────────────
   Virtual network   → vnet-myapp
   Subnet            → snet-aks (10.0.1.0/24)
   Public IP         → Create new
                        Name: pip-vpn-apim3
                        SKU: Standard
                        Assignment: Static  ← CRITICAL
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
  --subnet $AKS_SUBNET \
  --public-ip-address $PIP_VPN \
  --public-ip-sku Standard \
  --public-ip-address-allocation Static \
  --admin-username azureuser \
  --admin-password 'VpnAdmin@Apim3!'
```

### 3.2 Enable IP forwarding on VM NIC

```bash
NIC_ID=$(az vm show \
  --resource-group $RESOURCE_GROUP \
  --name $VPN_VM_NAME \
  --query "networkProfile.networkInterfaces[0].id" -o tsv)

az network nic update --ids $NIC_ID --ip-forwarding true

# Verify
az network nic show --ids $NIC_ID --query "enableIpForwarding" -o tsv
# Expected: true
```

**Portal alternative:**
```
Virtual Machines → vpn-vm-apim3 → Networking
→ click NIC name → Settings → IP configurations
→ Enable IP forwarding → ON → Save
```

### 3.3 NSG: allow UDP 1194 (OpenVPN)

```bash
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

### 3.4 Install OpenVPN inside VM

```bash
VPN_PUBLIC_IP=$(az network public-ip show \
  --resource-group $RESOURCE_GROUP \
  --name $PIP_VPN \
  --query ipAddress -o tsv)

echo "VPN public IP: $VPN_PUBLIC_IP"
ssh azureuser@$VPN_PUBLIC_IP
```

Once inside the VM:

```bash
# OS-level IP forwarding
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# Install
wget https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh
chmod +x openvpn-install.sh
sudo bash openvpn-install.sh
```

Installer prompts:
```
IP address        → press Enter (auto-detected public IP)
Protocol          → 1 (UDP)
Port              → press Enter (1194)
DNS resolver      → 11 (Custom)
  Primary DNS     → 168.63.129.16   ← Azure DNS, resolves privatelink zones
  Secondary DNS   → 8.8.8.8
Compression       → n
Custom encryption → n
Client name       → apim3-client
```

### 3.5 Download .ovpn to laptop

```bash
# Run from your LOCAL machine
scp azureuser@$VPN_PUBLIC_IP:/root/apim3-client.ovpn ~/apim3-client.ovpn
```

### 3.6 Connect from laptop

**Windows / Mac:** OpenVPN Connect → Import `apim3-client.ovpn` → Connect

**Linux:**
```bash
sudo apt install openvpn -y
sudo openvpn --config ~/apim3-client.ovpn
```

### 3.7 Verify VPN is working

```bash
ping 10.0.1.1   # VNet gateway reachable ✅
# (ping 10.0.3.4 after Phase 6)
# (psql to PostgreSQL after Phase 8)
```

**Phase 3 complete?** ⬜ VPN connected, `ping 10.0.1.1` works.

---

## Phase 4 — AKS: httpbin ILB + Entra ID RBAC

### 4.1 Deploy httpbin with Internal Load Balancer

> If `orders-svc` with EXTERNAL-IP `10.0.1.50` already exists from a prior lab, skip to 4.2.

```bash
# Confirm cluster credentials
az aks get-credentials \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_NAME \
  --overwrite-existing

kubectl get nodes   # verify cluster is reachable
```

**`httpbin-ilb.yaml`:**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: httpbin
  template:
    metadata:
      labels:
        app: httpbin
    spec:
      containers:
      - name: httpbin
        image: kennethreitz/httpbin
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: orders-svc
  namespace: default
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
    service.beta.kubernetes.io/azure-load-balancer-internal-subnet: "snet-aks"
spec:
  type: LoadBalancer
  loadBalancerIP: 10.0.1.50
  selector:
    app: httpbin
  ports:
  - port: 80
    targetPort: 80
```

```bash
kubectl apply -f httpbin-ilb.yaml

# Wait for ILB IP to be assigned (1-2 min)
kubectl get svc orders-svc -w
# EXTERNAL-IP must show 10.0.1.50 ✅
```

### 4.2 Enable Entra ID authentication on AKS (K8s RBAC mode)

```bash
# Check current state
az aks show \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_NAME \
  --query "aadProfile" -o json
# null                           → not enabled → run below
# managed:true, enableAzureRBAC:false → K8s RBAC mode already ✅ skip to 4.3
# managed:true, enableAzureRBAC:true  → Azure RBAC mode → see readme.md note

# Enable Entra ID — K8s RBAC mode (no --enable-azure-rbac)
az aks update \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_NAME \
  --enable-aad
# ⚠️ API server restarts — 2-3 min
```

### 4.3 Get admin (bootstrap) kubeconfig

```bash
az aks get-credentials \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_NAME \
  --admin \
  --overwrite-existing

kubectl get nodes   # ✅ certificate auth, no Entra popup
```

### 4.4 Create Entra ID test users and group

```bash
TENANT="<yourtenant>.onmicrosoft.com"   # ← replace

az ad user create \
  --display-name "Platform Engineer" \
  --user-principal-name platformeng@$TENANT \
  --password "PlatEng@Task10" \
  --force-change-password-next-sign-in false

az ad user create \
  --display-name "Backend Dev" \
  --user-principal-name backenddev@$TENANT \
  --password "BackDev@Task10" \
  --force-change-password-next-sign-in false

az ad user create \
  --display-name "Read Only User" \
  --user-principal-name readonly@$TENANT \
  --password "ReadOnly@Task10" \
  --force-change-password-next-sign-in false

# Collect Object IDs — used as subject names in RoleBinding YAML
MY_OID=$(az ad signed-in-user show --query id -o tsv)
PLAT_OID=$(az ad user show --id platformeng@$TENANT --query id -o tsv)
DEV_OID=$(az ad user show  --id backenddev@$TENANT  --query id -o tsv)
RO_OID=$(az ad user show   --id readonly@$TENANT    --query id -o tsv)

echo "Your OID        : $MY_OID"
echo "Platform OID    : $PLAT_OID"
echo "Backend Dev OID : $DEV_OID"
echo "Read Only OID   : $RO_OID"

az ad group create \
  --display-name "aks-orders-team" \
  --mail-nickname "aks-orders-team"

GROUP_OID=$(az ad group show --group "aks-orders-team" --query id -o tsv)
az ad group member add --group "aks-orders-team" --member-id $DEV_OID

echo "Group OID       : $GROUP_OID"
```

### 4.5 Create orders namespace + apply K8s RBAC bindings

```bash
kubectl create namespace orders
```

Create `rbac-orders.yaml` — fill in the four OIDs collected above:

```yaml
# 1. Your account → cluster-admin
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: crb-myaccount-cluster-admin
subjects:
- kind: User
  name: "<MY_OID>"          # ← paste $MY_OID
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
---
# 2. Platform engineer → cluster-admin
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: crb-platformeng-cluster-admin
subjects:
- kind: User
  name: "<PLAT_OID>"        # ← paste $PLAT_OID
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
---
# 3. aks-orders-team group → edit scoped to orders namespace
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: rb-orders-team-edit
  namespace: orders
subjects:
- kind: Group
  name: "<GROUP_OID>"       # ← paste $GROUP_OID
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: edit
  apiGroup: rbac.authorization.k8s.io
---
# 4. Read-only user → view cluster-wide
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: crb-readonly-view
subjects:
- kind: User
  name: "<RO_OID>"          # ← paste $RO_OID
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
```

> ⚠️ Subject `name` must be the **Object ID** (UUID), NOT the email address.
> K8s matches on the `oid` claim in the Entra token. Email never matches.

```bash
kubectl apply -f rbac-orders.yaml

# Verify bindings created
kubectl get clusterrolebindings | grep crb-
kubectl get rolebindings -n orders
```

### 4.6 Switch to Entra ID (non-admin) credentials

```bash
sudo az aks install-cli   # installs kubelogin

az aks get-credentials \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_NAME \
  --overwrite-existing

kubectl get nodes
# → browser popup → login with your Entra account → ✅ nodes appear
```

### 4.7 Test access as each identity

```bash
# --- Backend dev: orders namespace only ---
az login --username backenddev@$TENANT --password "BackDev@Task10"
az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_NAME --overwrite-existing

kubectl -n orders get pods        # ✅ Works (edit role)
kubectl -n default get pods       # ❌ Forbidden
kubectl get nodes                 # ❌ Forbidden

# --- Read-only: view cluster-wide ---
az login --username readonly@$TENANT --password "ReadOnly@Task10"
az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_NAME --overwrite-existing

kubectl get pods --all-namespaces # ✅ Works
kubectl delete pod <any>          # ❌ Forbidden
kubectl get secrets -n orders     # ❌ Forbidden (view excludes secrets)

# --- Return to admin ---
az login
az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_NAME --overwrite-existing
```

### 4.8 Break-glass verification

```bash
az aks get-credentials \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_NAME \
  --admin

kubectl get nodes   # ✅ no Entra popup — certificate auth
# ⚠️ Audit-logged — use for emergencies only

# Return to Entra credentials
az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_NAME --overwrite-existing
```

**Phase 4 complete?** ⬜ httpbin ILB at 10.0.1.50, RBAC bindings applied, all identity tests pass.

---

## Phase 5 — APIM Provisioning + TLS

> ⏱ APIM creation takes **30–45 minutes**. Start it and do Phase 6 in parallel.

### 5.1 Create public IP for APIM gateway

```bash
az network public-ip create \
  --name $PIP_APIM \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Standard \
  --allocation-method Static \
  --dns-name apim-myapp-pub

# Verify FQDN assigned
az network public-ip show \
  --resource-group $RESOURCE_GROUP \
  --name $PIP_APIM \
  --query "{IP:ipAddress, FQDN:dnsSettings.fqdn}" -o table
# Expected: IP: 20.x.x.x   FQDN: apim-myapp-pub.southindia.cloudapp.azure.com
```

### 5.2 Create APIM (External VNet mode)

**Portal:** `API Management` → `Create`

| Tab | Field | Value |
|---|---|---|
| Basics | Resource name | `apim-myapp-pub` |
| Basics | Pricing tier | `Developer` |
| Basics | Availability zones | **None / uncheck all** |
| Basics | Virtual network | `Virtual network` |
| Basics | Type | **`External`** |
| Basics | VNet | `vnet-myapp` |
| Basics | Subnet | `snet-apim` |
| Basics | Public IP Address | **`pip-apim-myapp-pub`** |
| Managed Identity | System assigned | **`On`** |

**CLI:**
```bash
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

az apim create \
  --resource-group $RESOURCE_GROUP \
  --name $APIM_NAME \
  --location $LOCATION \
  --publisher-name "My Company" \
  --publisher-email admin@abhijeetrajput.life \
  --sku-name Developer \
  --virtual-network-type External \
  --virtual-network-id /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Network/virtualNetworks/$VNET_NAME \
  --subnet-name $APIM_SUBNET \
  --public-ip-address $PIP_APIM \
  --enable-managed-identity
# ⏱ 30–45 minutes
```

### 5.3 Note APIM public and private IPs

```bash
# Public gateway IP (→ Hostinger A record in Phase 7)
APIM_PUBLIC_IP=$(az apim show \
  --resource-group $RESOURCE_GROUP \
  --name $APIM_NAME \
  --query "publicIpAddresses[0]" -o tsv)
echo "APIM public IP: $APIM_PUBLIC_IP"

# Private IP (should be 10.0.2.4)
az apim show \
  --resource-group $RESOURCE_GROUP \
  --name $APIM_NAME \
  --query "privateIpAddresses[0]" -o tsv
```

### 5.4 Get TLS certificate (Let's Encrypt DNS challenge)

```bash
# Install certbot (WSL / Ubuntu / macOS)
sudo apt update && sudo apt install certbot -y

# Request cert — DNS challenge (HTTP challenge won't work, APIM is in VNet)
sudo certbot certonly \
  --manual \
  --preferred-challenges dns \
  -d api.abhijeetrajput.life
# Certbot pauses and prints a TXT token — DO NOT press Enter yet
```

In Hostinger hPanel → Domains → `abhijeetrajput.life` → DNS/Nameservers → Add Record:

| Type | Name | Value | TTL |
|---|---|---|---|
| `TXT` | `_acme-challenge.api` | `<token certbot printed>` | `300` |

```bash
# Verify propagation — wait until this returns the token
dig TXT _acme-challenge.api.abhijeetrajput.life +short
# Only press Enter in certbot once the token appears here
```

### 5.5 Export cert as PFX and upload to APIM

```bash
sudo openssl pkcs12 -export \
  -in /etc/letsencrypt/live/api.abhijeetrajput.life/fullchain.pem \
  -inkey /etc/letsencrypt/live/api.abhijeetrajput.life/privkey.pem \
  -out ~/api.abhijeetrajput.life.pfx \
  -passout pass:YourPFXPassword

# Copy to Windows if using WSL
cp ~/api.abhijeetrajput.life.pfx /mnt/c/Users/<your-username>/Desktop/
```

**Portal:** `apim-myapp-pub` → `Deployment + infrastructure` → `Custom domains` → `+ Add`

| Field | Value |
|---|---|
| Type | `Gateway` |
| Hostname | `api.abhijeetrajput.life` |
| Certificate | Custom → upload `api.abhijeetrajput.life.pfx` |
| Certificate password | `YourPFXPassword` |
| Negotiate client certificate | Off |
| Default SSL binding | **On** |

Click **Save** (3–5 min).

**CLI alternative:**
```bash
CERT_B64=$(base64 -w 0 ~/api.abhijeetrajput.life.pfx)

az apim update \
  --resource-group $RESOURCE_GROUP \
  --name $APIM_NAME \
  --hostname-configurations '[{
    "type": "Proxy",
    "hostName": "api.abhijeetrajput.life",
    "negotiateClientCertificate": false,
    "defaultSslBinding": true,
    "certificatePassword": "YourPFXPassword",
    "encodedCertificate": "'"$CERT_B64"'"
  }]'
```

### 5.6 Verify custom domain is active

```bash
curl -sk -o /dev/null -w "HTTP %{http_code}\n" \
  https://api.abhijeetrajput.life/
# Expected: HTTP 401  ← APIM responded ✅
# SSL error → cert not saved or Default SSL binding not On
```

**Phase 5 complete?** ⬜ APIM provisioned, custom domain returns 401.

---

## Phase 6 — Application Gateway (WAF_v2, private frontend)

> Can be started while APIM is provisioning (Phase 5.2).

### 6.1 Create dummy public IP for AGW

```bash
az network public-ip create \
  --name $PIP_AGW \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Standard \
  --allocation-method Static
# No --dns-name — this IP is never used for DNS
```

### 6.2 Create WAF policy

```bash
az network application-gateway waf-policy create \
  --resource-group $RESOURCE_GROUP \
  --name $WAF_POLICY \
  --location $LOCATION
```

### 6.3 Create AGW

**Portal:** `Application Gateway` → `Create`

| Tab | Field | Value |
|---|---|---|
| Basics | Name | `agw-myapp-priv` |
| Basics | Tier | **`WAF v2`** |
| Networking | VNet / Subnet | `vnet-myapp` / `snet-agw` |
| Frontends | Frontend IP type | **`Both`** |
| Frontends | Public IP | `pip-agw-myapp-priv` (dummy) |
| Frontends | Private IP | `10.0.3.4` (static) |
| Backends | Pool name | `pool-aks` |
| Backends | Target type | **`IP address or FQDN`** |
| Backends | Target | `10.0.1.50` ← ILB IP, NOT VMSS |
| Configuration | Rule name | `rule-apim-to-aks` |
| Configuration | Rule priority | `100` |
| Configuration | Listener | `listener-http` · HTTP · port 80 · Frontend: **Private** |
| Configuration | Backend settings | `settings-aks` · HTTP · port 80 |
| Configuration | Routing rule type | `Basic` |
| WAF | Policy | `apim3-waf` (Detection mode) |

**CLI:**
```bash
az network application-gateway create \
  --resource-group $RESOURCE_GROUP \
  --name $AGW_NAME \
  --location $LOCATION \
  --sku WAF_v2 \
  --capacity 2 \
  --vnet-name $VNET_NAME \
  --subnet $AGW_SUBNET \
  --public-ip-address $PIP_AGW \
  --private-ip-address 10.0.3.4 \
  --servers 10.0.1.50 \
  --frontend-port 80 \
  --http-settings-port 80 \
  --http-settings-protocol Http \
  --routing-rule-type Basic \
  --waf-policy $WAF_POLICY
```

### 6.4 Add health probe

**Portal:** `agw-myapp-priv` → `Health probes` → `+ Add`

| Field | Value |
|---|---|
| Name | `probe-aks` |
| Protocol | `HTTP` |
| Pick host name from backend settings | `No` |
| Host | `10.0.1.50` |
| Pick port from backend settings | `Yes` |
| Path | `/get` |
| Interval | `30` |
| Timeout | `30` |
| Unhealthy threshold | `3` |
| Backend settings | `settings-aks` |

Click **Test** → must return 200 → **Save**.

### 6.5 Verify backend health and WAF

```bash
# Backend must be Healthy
az network application-gateway show-backend-health \
  --resource-group $RESOURCE_GROUP \
  --name $AGW_NAME \
  --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].{IP:address, Health:health}" \
  -o table
# Expected: 10.0.1.50  Healthy

# WAF policy attached
az network application-gateway show \
  --resource-group $RESOURCE_GROUP \
  --name $AGW_NAME \
  --query "firewallPolicy.id" -o tsv
# Expected: .../apim3-waf

# WAF in Detection mode (not Prevention)
az network application-gateway waf-policy show \
  --resource-group $RESOURCE_GROUP \
  --name $WAF_POLICY \
  --query "policySettings.mode" -o tsv
# Expected: Detection
```

### 6.6 Verify AGW is reachable via VPN

```bash
# Must be on VPN
curl http://10.0.3.4/get
# Expected: httpbin JSON ✅  confirms AGW → ILB → pod chain works
```

**Phase 6 complete?** ⬜ AGW healthy, `curl 10.0.3.4/get` returns httpbin JSON.

---

## Phase 7 — APIM API + Policies + DNS

### 7.1 Create the Orders API

**Portal:** `apim-myapp-pub` → `APIs` → `+ Add API` → `HTTP`

| Field | Value |
|---|---|
| Display name | `Orders API` |
| Name | `orders-api` |
| Web service URL | `http://10.0.3.4` |
| URL scheme | `HTTPS` |
| API URL suffix | `orders` |
| Subscription required | ✔️ on |

Click **Create**.

### 7.2 Add operations

**Portal:** `Orders API` → `Design` → `+ Add operation` (save after each)

| Display name | Method | URL path |
|---|---|---|
| `Get` | `GET` | `/get` |
| `Post` | `POST` | `/post` |
| `Headers` | `GET` | `/headers` |
| `IP` | `GET` | `/ip` |

Resulting full URLs:
- `https://api.abhijeetrajput.life/orders/get`
- `https://api.abhijeetrajput.life/orders/post`
- `https://api.abhijeetrajput.life/orders/headers`
- `https://api.abhijeetrajput.life/orders/ip`

### 7.3 Apply inbound policies

Get tenant and app IDs first:

```bash
TENANT_ID=$(az account show --query tenantId -o tsv)
APP_ID=$(az ad app list --display-name "orders-api" --query "[0].appId" -o tsv)
echo "Tenant : $TENANT_ID"
echo "App ID : $APP_ID"
```

**Portal:** `Orders API` → `Design` → `All operations` → `</>` (Inbound processing)

Paste the full block — replace `{tenant-id}` and `{app-id}`:

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

Click **Save**. Verify no red error banner.

> ⚠️ If `api://orders` is blocked by tenant policy, use `api://{app-id}` as the audience value.
> Also ensure a service principal exists: `az ad sp create --id $APP_ID`

### 7.4 Point DNS to APIM public IP

In Hostinger hPanel → Domains → `abhijeetrajput.life` → DNS/Nameservers:

| Type | Name | Points to | TTL |
|---|---|---|---|
| `A` | `api` | `<APIM_PUBLIC_IP>` | `300` |

```bash
# Verify propagation
dig api.abhijeetrajput.life +short
# Must return APIM public IP (NOT AGW IP)
```

**Phase 7 complete?** ⬜ API created with policies, DNS resolves to APIM public IP.

---

## Phase 8 — PostgreSQL Private Link

### 8.1 Create delegated subnet for PostgreSQL

```bash
az network vnet subnet create \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name $PG_SUBNET \
  --address-prefixes 10.0.4.0/24 \
  --delegations Microsoft.DBforPostgreSQL/flexibleServers

# Verify
az network vnet subnet show \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name $PG_SUBNET \
  --query "delegations[].serviceName" -o tsv
# Expected: Microsoft.DBforPostgreSQL/flexibleServers
```

> ⚠️ Do NOT attach NSG, UDR, or private subnet flag to `snet-postgres`. Any of these cause PostgreSQL provisioning to fail permanently.

### 8.2 Create PostgreSQL Flexible Server

**Portal:**
```
Search "Azure Database for PostgreSQL flexible servers" → + Create

── Basics ──────────────────────────────────────────────────
   Resource group     → rg-myapp
   Server name        → pg-task10
   Region             → South India
   PostgreSQL version → 16
   Workload type      → Development
   Compute + storage  → Burstable, Standard_B1ms, 32 GiB, HA: Disabled
   Admin username     → pgadmin
   Password           → PgAdmin@Task10!

── Networking ──────────────────────────────────────────────
   Connectivity       → Private access (VNet Integration)  ← KEY
   Virtual network    → vnet-myapp
   Subnet             → snet-postgres
   Private DNS Zone   → Create new (auto-named)

→ Review + Create → Create   ⏱ 5–7 min
```

**CLI:**
```bash
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
  --subnet $PG_SUBNET \
  --private-dns-zone "${PG_NAME}.private.postgres.database.azure.com" \
  --yes
```

### 8.3 Verify Private DNS Zone and VNet link

```bash
az network private-dns zone show \
  --resource-group $RESOURCE_GROUP \
  --name "${PG_NAME}.private.postgres.database.azure.com" \
  --query name -o tsv

az network private-dns link vnet list \
  --resource-group $RESOURCE_GROUP \
  --zone-name "${PG_NAME}.private.postgres.database.azure.com" \
  --query "[].{Name:name, State:provisioningState}" -o table
# Expected: Succeeded

# If VNet link is missing
az network private-dns link vnet create \
  --resource-group $RESOURCE_GROUP \
  --zone-name "${PG_NAME}.private.postgres.database.azure.com" \
  --name link-vnet-myapp \
  --virtual-network $VNET_NAME \
  --registration-enabled false
```

### 8.4 Test DNS resolution and create app database

```bash
kubectl run psql-client \
  --image=postgres:16 \
  --restart=Never \
  --rm -it \
  -- bash

# Inside pod
nslookup pg-task10.postgres.database.azure.com
# MUST return 10.0.4.x — if returns public IP, DNS Zone link is missing

psql -h pg-task10.postgres.database.azure.com -U pgadmin -d postgres
# password: PgAdmin@Task10!

CREATE DATABASE ordersdb;
CREATE USER ordersuser WITH PASSWORD 'Orders@Task10!';
GRANT ALL PRIVILEGES ON DATABASE ordersdb TO ordersuser;
\q
exit
```

### 8.5 Store credentials as K8s Secret

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

### 8.6 Verify no public access

```bash
# From your laptop (outside pod) — must fail
psql -h pg-task10.postgres.database.azure.com -U pgadmin -d postgres
# Expected: connection timeout ✅
```

### 8.7 Apply NetworkPolicy

**`netpol-orders-db.yaml`:**

```yaml
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
```

**Phase 8 complete?** ⬜ nslookup returns private IP, K8s Secret created, NetworkPolicy applied.

---

## Phase 9 — Workload Identity + Key Vault

### 9.1 Enable OIDC issuer + Workload Identity on AKS

```bash
az aks show \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_NAME \
  --query "oidcIssuerProfile" -o json
# If enabled: true → skip the update

az aks update \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_NAME \
  --enable-oidc-issuer \
  --enable-workload-identity
```

### 9.2 Create Key Vault and store secret

```bash
az keyvault create \
  --resource-group $RESOURCE_GROUP \
  --name $KV_NAME \
  --location $LOCATION \
  --sku standard \
  --enable-rbac-authorization true

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

### 9.3 Create Managed Identity

```bash
az identity create \
  --resource-group $RESOURCE_GROUP \
  --name $WI_NAME \
  --location $LOCATION

WI_CLIENT_ID=$(az identity show \
  --resource-group $RESOURCE_GROUP --name $WI_NAME \
  --query clientId -o tsv)

WI_PRINCIPAL_ID=$(az identity show \
  --resource-group $RESOURCE_GROUP --name $WI_NAME \
  --query principalId -o tsv)

echo "Client ID   : $WI_CLIENT_ID"
echo "Principal ID: $WI_PRINCIPAL_ID"

sleep 60   # wait for Entra ID replication
```

### 9.4 Assign Key Vault Secrets User role

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

> ⚠️ Key Vault must use Azure RBAC permission model (not access policy).
> Check: `az keyvault show --name $KV_NAME --query "properties.enableRbacAuthorization"` → must be `true`

### 9.5 Create federated credential

```bash
AKS_OIDC_ISSUER=$(az aks show \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_NAME \
  --query "oidcIssuerProfile.issuerUrl" -o tsv)

echo "OIDC Issuer: $AKS_OIDC_ISSUER"

az identity federated-credential create \
  --name apim3-federated-cred \
  --identity-name $WI_NAME \
  --resource-group $RESOURCE_GROUP \
  --issuer $AKS_OIDC_ISSUER \
  --subject "system:serviceaccount:orders:orders-sa" \
  --audience api://AzureADTokenExchange
```

> ⚠️ Namespace `orders` and service account name `orders-sa` must exactly match what you create in 9.6. Mismatch → silent 401 from Key Vault.

### 9.6 Create Kubernetes ServiceAccount

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

### 9.7 Deploy pod and read Key Vault secret

**`kv-reader-pod.yaml`:**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kv-reader
  namespace: orders
  labels:
    azure.workload.identity/use: "true"
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

kubectl exec -it kv-reader -n orders -- \
  az keyvault secret show \
  --vault-name $KV_NAME \
  --name pg-orders-password \
  --query value -o tsv
# Expected: Orders@Task10! ✅
```

**Phase 9 complete?** ⬜ Pod reads KV secret without any credentials in its spec.

---

## Phase 10 — Blob Storage via Workload Identity

> Reuses `orders-sa` ServiceAccount and `wi-apim3` Managed Identity from Phase 9.

### 10.1 Create Storage Account and container

```bash
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

# Upload a test file
echo '{"order_id": "ORD-001", "amount": 4999, "status": "paid"}' > receipt-001.json

az storage blob upload \
  --account-name $STORAGE_NAME \
  --container-name orders-receipts \
  --name receipt-001.json \
  --file receipt-001.json \
  --auth-mode login

echo "Test file uploaded ✅"
```

### 10.2 Assign blob role to Managed Identity

```bash
STORAGE_SCOPE=$(az storage account show \
  --name $STORAGE_NAME \
  --resource-group $RESOURCE_GROUP \
  --query id -o tsv)

# Scoped to the specific container — least privilege
az role assignment create \
  --assignee-object-id $WI_PRINCIPAL_ID \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope "$STORAGE_SCOPE/blobServices/default/containers/orders-receipts"
```

> ⚠️ Must use `Storage Blob Data Contributor` (data plane), not `Contributor` (management plane).

### 10.3 Deploy pod and test blob read/write

**`blob-orders-pod.yaml`:**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: blob-orders
  namespace: orders
  labels:
    azure.workload.identity/use: "true"
spec:
  serviceAccountName: orders-sa
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

# Read blob — Workload Identity token, no account key
kubectl exec -it blob-orders -n orders -- \
  az storage blob download \
  --account-name $STORAGE_NAME \
  --container-name orders-receipts \
  --name receipt-001.json \
  --file /tmp/receipt-001.json \
  --auth-mode login

kubectl exec -it blob-orders -n orders -- cat /tmp/receipt-001.json
# Expected: {"order_id": "ORD-001", "amount": 4999, "status": "paid"} ✅

# Write blob from pod
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

### 10.4 Verify from laptop (via VPN)

```bash
az storage blob list \
  --account-name $STORAGE_NAME \
  --container-name orders-receipts \
  --auth-mode login \
  --query "[].name" -o tsv
# Expected: receipt-001.json, receipt-002.json ✅
```

**Phase 10 complete?** ⬜ Pod downloads and uploads blobs using Workload Identity.

---

## Phase 11 — End-to-End Test Scenarios

Get a JWT first:

```bash
SECRET="<your-app-client-secret>"
TENANT_ID=$(az account show --query tenantId -o tsv)
APP_ID=$(az ad app list --display-name "orders-api" --query "[0].appId" -o tsv)

TOKEN=$(curl -s -X POST \
  "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token" \
  -d "grant_type=client_credentials" \
  -d "client_id=$APP_ID" \
  -d "client_secret=$SECRET" \
  -d "scope=api://$APP_ID/.default" \
  | jq -r .access_token)

echo "Token: ${TOKEN:0:50}..."
```

Get subscription key:

```bash
SUB_KEY=$(az apim subscription list \
  --resource-group $RESOURCE_GROUP \
  --service-name $APIM_NAME \
  --query "[0].primaryKey" -o tsv)
echo "Sub key: $SUB_KEY"
```

---

### Scenario 1 — No JWT → 401

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  https://api.abhijeetrajput.life/orders/get
# Expected: HTTP 401 ✅
```

### Scenario 2 — Bad JWT → 401

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  -H "Authorization: Bearer fake.token" \
  -H "Ocp-Apim-Subscription-Key: $SUB_KEY" \
  https://api.abhijeetrajput.life/orders/get
# Expected: HTTP 401 ✅
```

### Scenario 3 — Happy path → 200

```bash
curl -s -w "\nHTTP %{http_code}\n" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Ocp-Apim-Subscription-Key: $SUB_KEY" \
  https://api.abhijeetrajput.life/orders/get
# Expected: HTTP 200 + httpbin JSON ✅
# X-Appgw-Trace-Id in response headers → confirms traffic passed through AGW
# origin field → 10.0.2.x → confirms APIM forwarded via its private IP
```

### Scenario 4 — Authorization header stripped at pod

```bash
curl -s \
  -H "Authorization: Bearer $TOKEN" \
  -H "Ocp-Apim-Subscription-Key: $SUB_KEY" \
  https://api.abhijeetrajput.life/orders/headers | jq .headers
# Expected: no "Authorization" key in output ✅
# (Ocp-Apim-Subscription-Key will still be present — that is correct behaviour)
```

### Scenario 5 — Rate limit → 429

```bash
for i in $(seq 1 210); do
  curl -s -o /dev/null -w "Request $i: %{http_code}\n" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Ocp-Apim-Subscription-Key: $SUB_KEY" \
    https://api.abhijeetrajput.life/orders/get
done
# Requests 1–200: HTTP 200
# Requests 201+:  HTTP 429 ✅
# Note: refresh $TOKEN if loop takes more than ~1 hour
```

### Scenario 6 — Private AGW unreachable from internet

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" --connect-timeout 5 \
  http://10.0.3.4/orders/get
# Expected: timeout (HTTP 000) ✅  — AGW has no public exposure
```

---

### All scenarios at a glance

| # | Scenario | Handled by | Expected | Result |
|---|---|---|---|---|
| 1 | No JWT | APIM validate-jwt | 401 | ⬜ |
| 2 | Bad JWT | APIM validate-jwt | 401 | ⬜ |
| 3 | Happy path | Full chain | 200 | ⬜ |
| 4 | Auth header stripped | APIM set-header delete | No Authorization at pod | ⬜ |
| 5 | Rate limit | APIM rate-limit-by-key | 429 after 200 calls | ⬜ |
| 6 | AGW unreachable from internet | NSG on snet-agw | Timeout | ⬜ |

**Phase 11 complete?** ⬜ All 6 scenarios produce the expected result.

---

## Full completion checklist

```
Phase 1  — Shell vars + pre-checks             ⬜
Phase 2  — NSG rules verified                  ⬜
Phase 3  — VPN connected, ping 10.0.1.1 ✅     ⬜
Phase 4  — httpbin ILB 10.0.1.50, RBAC done   ⬜
Phase 5  — APIM live, custom domain → 401      ⬜
Phase 6  — AGW backend 10.0.1.50 Healthy       ⬜
Phase 7  — API + policies, DNS → APIM IP       ⬜
Phase 8  — PG private, DNS → 10.0.4.x         ⬜
Phase 9  — KV secret read from pod (no creds)  ⬜
Phase 10 — Blob read/write from pod (no keys)  ⬜
Phase 11 — All 6 test scenarios pass           ⬜
```

## Quick troubleshooting reference

| Symptom | Most likely cause | Fix |
|---|---|---|
| APIM create fails: "IP must have FQDN" | IP has no DNS label | `az network public-ip create` with `--dns-name` |
| AGW create blocked in portal | NSG missing GatewayManager rule | Add `allow-agw-infra` rule (Phase 2) |
| 502 from APIM | APIM can't reach AGW `10.0.3.4` | Check NSG `allow-apim-to-agw-out` outbound on `nsg-apim` |
| 502 from AGW | VMSS node IP in backend pool | Update pool to `10.0.1.50` only |
| `curl 10.0.3.4` fails from laptop | Not on VPN or IP forwarding off | Connect VPN; verify NIC IP forwarding ON |
| nslookup returns public IP for PG | DNS Zone not linked to VNet | Add VNet link to private DNS zone (Phase 8.3) |
| kubectl Forbidden after Entra login | RoleBinding subject is email not OID | Re-apply `rbac-orders.yaml` with Object IDs |
| KV 401 from pod | Federated credential namespace/SA mismatch | Verify `--subject system:serviceaccount:orders:orders-sa` |
| Blob 403 | Wrong role (Contributor not Blob Data Contributor) | Assign `Storage Blob Data Contributor` at container scope |
| OpenVPN connects but can't reach 10.0.x.x | IP forwarding not on NIC | Portal: VM NIC → IP configurations → IP forwarding ON |
| OpenVPN can't resolve privatelink hostnames | DNS not set to 168.63.129.16 | Re-run angristan installer with Custom DNS 168.63.129.16 |
