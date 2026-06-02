# App Service with Load Balancer — Application Gateway (L7)

> **Goal:** Host a web app on Azure App Service, place an **Application Gateway (v2)**
> in front of it for Layer-7 load balancing and SSL offload.
> Lock the App Service so traffic can only come through the gateway — no one bypasses it.

This guide includes **two deployment paths**:

| Path | Security model | Best for |
|------|----------------|----------|
| **[Path A](#path-a--architecture-access-restrictions)** | Public app endpoint **On** + **access restrictions** (allow `subnet-appgw` only) | Lab / simpler setup (CLI steps below) |
| **[Path B](#path-b--architecture-private-link--agw)** | **Public access Off** + **private endpoint** + AGW over **Private Link** | Production / zero public exposure on the app |

---

## Path A — Architecture (access restrictions)

```
Internet
    │
    │ HTTPS (port 443)
    ▼
┌──────────────────────────────────────────────────────────────────────┐
│  Application Gateway (v2)                                            │
│  subnet-appgw (10.10.1.0/24) — min /26                              │
│                                                                      │
│  Frontend IP: pip-appgw (public)                                     │
│  Listener:    HTTP :80 (HTTPS optional)                              │
│  Backend pool: app-task08.azurewebsites.net                          │
│  Health probe: HTTP GET / → expects 200                              │
└──────────────────────────┬───────────────────────────────────────────┘
                           │
                  Private channel via
                  VNet Integration
                           │
┌──────────────────────────▼───────────────────────────────────────────┐
│  App Service (Standard S1 or higher)                                 │
│  VNet Integration → subnet-appservice (10.10.2.0/24)                │
│  Access Restriction: ALLOW only subnet-appgw                        │
│  All other sources → DENY 403                                        │
└──────────────────────────────────────────────────────────────────────┘

Flow:
  1. User → hits pip-appgw (public IP)
  2. App Gateway forwards request to App Service (via VNet) using app hostname
  3. App Service checks access restriction → subnet-appgw allowed → serves response
  4. Response goes back: App Service → App Gateway → User
```

> Direct `https://<app>.azurewebsites.net` is blocked in **Step 8** (403), not by disabling the platform public endpoint.

---

## Path B — Architecture (Private Link + AGW)

Internet users never touch the App Service public endpoint. Only the Application Gateway has a public IP.

```
Internet
    │
    │ HTTP/HTTPS
    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  Application Gateway (v2) — subnet-appgw (10.10.1.0/24)                  │
│  Public IP: pip-appgw                                                   │
│  Backend pool hostname: app-task08.azurewebsites.net                    │
│  (resolves to PRIVATE IP inside VNet via Private DNS)                   │
└────────────────────────────┬────────────────────────────────────────────┘
                             │ HTTPS → private IP (e.g. 10.10.3.5)
                             ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  Private Endpoint (sites) — subnet-pe-app (10.10.3.0/24)                │
│  NIC IP: 10.10.3.5                                                      │
└────────────────────────────┬────────────────────────────────────────────┘
                             │
┌────────────────────────────▼────────────────────────────────────────────┐
│  App Service                                                            │
│  Public network access: DISABLED                                        │
│  Inbound: only via private endpoint                                     │
│  Outbound VNet integration: subnet-appservice (10.10.2.0/24)           │
└─────────────────────────────────────────────────────────────────────────┘

Private DNS Zone: privatelink.azurewebsites.net
  A record: app-task08 → 10.10.3.5
  (linked to vnet-task08 — AGW and app resolve hostname privately)

Flow:
  1. User → pip-appgw (only public entry)
  2. AGW resolves app hostname → private IP (Private DNS)
  3. AGW → private endpoint → App Service
  4. Direct https://app.azurewebsites.net from Internet → fails (public access off)
```

**Path B needs three subnets** (add **`subnet-pe-app`** for the app private endpoint):

| Subnet | Purpose |
|--------|---------|
| `subnet-appgw` | Application Gateway only |
| `subnet-appservice` | App Service **outbound** VNet integration (`Microsoft.Web/serverFarms` delegation) |
| `subnet-pe-app` | App Service **inbound** private endpoint |

---

## Why Application Gateway (not just App Service's built-in LB)

| Need | App Service built-in | Application Gateway |
|---|---|---|
| Basic load balancing across instances | ✅ automatic | ✅ |
| Custom routing (path-based, host-based) | ❌ | ✅ |
| SSL termination at gateway | ❌ | ✅ |
| Multi-app / multi-region routing | ❌ | ✅ |
| DDoS protection integration | ❌ | ✅ |

Use Application Gateway when you need custom routing, SSL offload, or a single
entry point in front of multiple backends. For **WAF**, use **Application Gateway WAF v2**
or **Azure Front Door** (not covered in this lab).
For global multi-region routing, use **Azure Front Door**.

---

## PRE-STEP — Environment Variables

```bash
LOCATION="southindia"
RG="rg-appservice-lb"
VNET_NAME="vnet-task08"
APP_NAME="app-task08-$RANDOM"   # must be globally unique
APP_PLAN="plan-task08"
APPGW_NAME="appgw-task08"
PE_APP_NAME="pe-app-task08"     # Path B only
DNS_ZONE_APP="privatelink.azurewebsites.net"

echo "App Service name: $APP_NAME"
# Save this — used in backend pool configuration
```

---

# Path A — CLI (access restrictions)

Steps 1–9 below. For **Private Link + public access disabled**, use [Path B — CLI](#path-b--cli-private-link--agw) and [Path B — Portal](#path-b--azure-portal--manual-steps-secure).

---

## Step 1 — Create Resource Group

```bash
az group create \
  --name $RG \
  --location $LOCATION
```

---

## Step 2 — Create VNet with Two Subnets

```bash
# Main VNet
az network vnet create \
  --resource-group $RG \
  --name $VNET_NAME \
  --location $LOCATION \
  --address-prefixes 10.10.0.0/16

# Subnet for Application Gateway — minimum /26 (64 IPs) required
az network vnet subnet create \
  --resource-group $RG \
  --vnet-name $VNET_NAME \
  --name subnet-appgw \
  --address-prefixes 10.10.1.0/24

# Subnet for App Service VNet Integration
az network vnet subnet create \
  --resource-group $RG \
  --vnet-name $VNET_NAME \
  --name subnet-appservice \
  --address-prefixes 10.10.2.0/24
```

> App Gateway requires its own **dedicated subnet** — no other resources can share it.
> The subnet must be at least /26 (Azure reserves IPs for gateway instances).

---

## Step 3 — Create App Service Plan + Web App

```bash
# Standard tier or higher is required for VNet Integration
az appservice plan create \
  --resource-group $RG \
  --name $APP_PLAN \
  --location $LOCATION \
  --sku S1 \
  --is-linux

# Create the web app (Node.js 20 LTS — change runtime as needed)
az webapp create \
  --resource-group $RG \
  --plan $APP_PLAN \
  --name $APP_NAME \
  --runtime "NODE:20-lts"

echo "App Service URL: https://$APP_NAME.azurewebsites.net"
```

Verify the app is responding:

```bash
curl -s -o /dev/null -w "%{http_code}" https://$APP_NAME.azurewebsites.net/
# Expected: 200 (or 403 before we set up access restrictions)
```

---

## Step 4 — Enable VNet Integration on App Service

This lets the App Service make **outbound** calls into the VNet, and lets the VNet
control inbound access via subnet-level restrictions.

```bash
az webapp vnet-integration add \
  --resource-group $RG \
  --name $APP_NAME \
  --vnet $VNET_NAME \
  --subnet subnet-appservice
```

Verify integration:

```bash
az webapp vnet-integration list \
  --resource-group $RG \
  --name $APP_NAME \
  -o table

# Expected:
# Name              SubnetResourceId
# ────────────────  ─────────────────────────────────────────────────
# subnet-appservice /subscriptions/.../subnet-appservice
```

---

## Step 5 — Create Public IP for Application Gateway

```bash
az network public-ip create \
  --resource-group $RG \
  --name pip-appgw \
  --location $LOCATION \
  --sku Standard \
  --allocation-method Static

APPGW_PUBLIC_IP=$(az network public-ip show \
  --resource-group $RG \
  --name pip-appgw \
  --query ipAddress -o tsv)

echo "App Gateway public IP: $APPGW_PUBLIC_IP"
```

---

## Step 6 — Create Application Gateway (v2)

This single command creates the gateway with **Standard v2** SKU, a frontend listener on
port 80 (HTTP — HTTPS on the listener is an optional extension), and a backend pointing to the App Service:

```bash
az network application-gateway create \
  --resource-group $RG \
  --name $APPGW_NAME \
  --location $LOCATION \
  --sku Standard_v2 \
  --capacity 1 \
  --vnet-name $VNET_NAME \
  --subnet subnet-appgw \
  --public-ip-address pip-appgw \
  --frontend-port 80 \
  --http-settings-port 443 \
  --http-settings-protocol Https \
  --servers "$APP_NAME.azurewebsites.net" \
  --priority 100

echo "Application Gateway created: $APPGW_NAME"
```

> `--capacity 1` = single instance (fine for lab). Production: use 2+ or autoscale.
> `--http-settings-protocol Https` = gateway talks to App Service over HTTPS (port 443).
> App Service only accepts HTTPS by default — always use HTTPS on the backend.

---

## Step 7 — Configure Backend Health Probe

```bash
# Add a custom health probe (optional but recommended)
az network application-gateway probe create \
  --resource-group $RG \
  --gateway-name $APPGW_NAME \
  --name probe-appservice \
  --protocol Https \
  --host-name-from-http-settings true \
  --path "/" \
  --interval 30 \
  --timeout 30 \
  --threshold 3

# Associate probe with backend HTTP settings
az network application-gateway http-settings update \
  --resource-group $RG \
  --gateway-name $APPGW_NAME \
  --name appGatewayBackendHttpSettings \
  --probe probe-appservice \
  --host-name-from-backend-pool true

echo "Health probe configured"
```

Check backend health:

```bash
az network application-gateway show-backend-health \
  --resource-group $RG \
  --name $APPGW_NAME \
  --query "backendAddressPools[0].backendHttpSettingsCollection[0].servers[0].{Address:address,Health:health}" \
  -o json

# Expected:
# {
#   "Address": "app-task08-<random>.azurewebsites.net",
#   "Health": "Healthy"
# }
```

---

## Step 8 — Lock App Service: Allow Only App Gateway Subnet

This is critical. Without this restriction, anyone who knows the App Service hostname
(`app-task08.azurewebsites.net`) can bypass Application Gateway and hit the app directly.

```bash
# Get subnet resource ID for subnet-appgw
APPGW_SUBNET_ID=$(az network vnet subnet show \
  --resource-group $RG \
  --vnet-name $VNET_NAME \
  --name subnet-appgw \
  --query id -o tsv)

# Add access restriction: allow only the App Gateway subnet
az webapp config access-restriction add \
  --resource-group $RG \
  --name $APP_NAME \
  --priority 100 \
  --action Allow \
  --vnet-name $VNET_NAME \
  --subnet subnet-appgw \
  --rule-name "allow-appgw-subnet"

# Deny all other traffic (default is already Deny, but be explicit)
az webapp config access-restriction set \
  --resource-group $RG \
  --name $APP_NAME \
  --use-same-restrictions-for-scm-site true

# Verify restriction is in place
az webapp config access-restriction show \
  --resource-group $RG \
  --name $APP_NAME \
  --query "ipSecurityRestrictions[].{Name:name, Action:action, Priority:priority, Subnet:vnetSubnetResourceId}" \
  -o table
```

---

## Step 9 — Test End-to-End

Test via Application Gateway (should work):

```bash
# Hit the App Gateway's public IP
curl -I http://$APPGW_PUBLIC_IP/

# Expected:
# HTTP/1.1 200 OK
# Server: Microsoft-IIS/...
# ...
```

Test direct App Service access (should be blocked):

```bash
curl -I https://$APP_NAME.azurewebsites.net/

# Expected:
# HTTP/1.1 403 Forbidden
# X-Azure-Ref: ...
# Proves the access restriction is working — App Gateway is the only allowed path
```

---

## Path-Based Routing (Optional Extension)

Route different URL paths to different backends:

```bash
# Example: /api/* → backend-api, /* → backend-web
az network application-gateway url-path-map create \
  --resource-group $RG \
  --gateway-name $APPGW_NAME \
  --name url-path-map \
  --paths "/api/*" \
  --address-pool appGatewayBackendPool \
  --http-settings appGatewayBackendHttpSettings \
  --rule-name api-rule \
  --default-address-pool appGatewayBackendPool \
  --default-http-settings appGatewayBackendHttpSettings
```

For multiple App Services (multi-region), use **Azure Front Door** instead — it provides
global routing and failover across regions.

---

# Path B — CLI (Private Link + AGW)

Complete Path A **Steps 1–3** (RG, VNet with **`subnet-appgw`** + **`subnet-appservice`**, App Service plan + web app), then:

## Step B1 — Add subnet for App Service private endpoint

```bash
az network vnet subnet create \
  --resource-group $RG \
  --vnet-name $VNET_NAME \
  --name subnet-pe-app \
  --address-prefixes 10.10.3.0/24

az network vnet subnet update \
  --resource-group $RG \
  --vnet-name $VNET_NAME \
  --name subnet-pe-app \
  --disable-private-endpoint-network-policies true
```

## Step B2 — Private endpoint for the web app

```bash
APP_ID=$(az webapp show \
  --resource-group $RG \
  --name $APP_NAME \
  --query id -o tsv)

az network private-endpoint create \
  --resource-group $RG \
  --name $PE_APP_NAME \
  --location $LOCATION \
  --vnet-name $VNET_NAME \
  --subnet subnet-pe-app \
  --private-connection-resource-id $APP_ID \
  --group-id sites \
  --connection-name "pe-app-conn"
```

## Step B3 — Private DNS zone (if not auto-created)

```bash
az network private-dns zone create \
  --resource-group $RG \
  --name $DNS_ZONE_APP

az network private-dns link vnet create \
  --resource-group $RG \
  --zone-name $DNS_ZONE_APP \
  --name link-vnet-app \
  --virtual-network $VNET_NAME \
  --registration-enabled false

PE_IP=$(az network private-endpoint show \
  --resource-group $RG \
  --name $PE_APP_NAME \
  --query "customDnsConfigs[0].ipAddresses[0]" -o tsv)

az network private-dns record-set a create \
  --resource-group $RG \
  --zone-name $DNS_ZONE_APP \
  --name $APP_NAME

az network private-dns record-set a add-record \
  --resource-group $RG \
  --zone-name $DNS_ZONE_APP \
  --record-set-name $APP_NAME \
  --ipv4-address $PE_IP

echo "Private endpoint IP: $PE_IP"
```

> Portal tip: when creating the PE, choose **Integrate with private DNS zone = Yes** to skip manual DNS steps.

## Step B4 — Disable public network access on App Service

```bash
az webapp update \
  --resource-group $RG \
  --name $APP_NAME \
  --public-network-access Disabled

az webapp show \
  --resource-group $RG \
  --name $APP_NAME \
  --query "publicNetworkAccess" -o tsv
# Expected: Disabled
```

## Step B5 — VNet integration (outbound) if not done

```bash
az webapp vnet-integration add \
  --resource-group $RG \
  --name $APP_NAME \
  --vnet $VNET_NAME \
  --subnet subnet-appservice
```

## Step B6 — Application Gateway (Steps 5–7 from Path A)

Create **`pip-appgw`**, **Application Gateway (Standard v2)** on **`subnet-appgw`**, backend pool FQDN
**`<APP_NAME>.azurewebsites.net`**, backend **HTTPS 443**, health probe.

AGW in the same VNet uses **Private DNS** to resolve the hostname to the **private endpoint IP**.

Path B does **not** require Path A **Step 8** (access restrictions) — public inbound to the app is already disabled.

## Step B7 — Test (Path B)

```bash
# Via AGW — should work
curl -I http://$APPGW_PUBLIC_IP/

# Direct app URL from laptop — should FAIL (public access disabled)
curl -I https://$APP_NAME.azurewebsites.net/
# Expected: timeout, connection refused, or not reachable — not 200
```

---

## Quick Summary — Which Tool for What

| Scenario | Azure Tool |
|---|---|
| Single region, SSL offload, path routing | Application Gateway (v2) |
| Single region + WAF (OWASP) | Application Gateway **WAF v2** or Azure Front Door |
| Global multi-region, failover, CDN | Azure Front Door |
| Simple internal load balancing (VMs) | Azure Load Balancer (L4) |
| DNS-based global routing | Azure Traffic Manager |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Backend health: Unhealthy | Probe fails on App Service | Check `--host-name-from-backend-pool true` on probe |
| 502 Bad Gateway from App Gateway | App Service returning non-200 or unreachable | Check App Service is running; check access restrictions |
| App Service still accessible directly | Access restriction not saved | Re-run Step 8; verify with `access-restriction show` |
| Gateway creation fails on subnet size | Subnet too small | App Gateway needs /26 minimum (64 IPs) |
| `az webapp vnet-integration add` fails | SKU too low | Upgrade to Standard S1 or higher |
| Path B: AGW backend **Unhealthy** | Private DNS missing / wrong A record | Verify `privatelink.azurewebsites.net` → app name → PE IP; PE in same VNet as AGW |
| Path B: AGW **502** after public access off | AGW not using private DNS resolution | AGW must be in VNet with DNS zone linked; backend host = app FQDN |
| Path B: App still reachable publicly | Public network access still **Enabled** | Set **Disabled** on app; verify `publicNetworkAccess` |

---

## Cleanup

```bash
az group delete --name $RG --yes --no-wait
```

---

## Azure Portal — Manual Steps (Path A)

Use these for **access restrictions** (public app endpoint **On**, locked down in Step 8).
For **Private Link + public access Off**, use [Path B — Portal](#path-b--azure-portal--manual-steps-secure) below.

Names match the lab (`rg-appservice-lb`, `vnet-task08`, `appgw-task08`, etc.).

### Step 1 — Resource group

1. [Azure Portal](https://portal.azure.com/) → **Resource groups** → **Create**.
2. Name **`rg-appservice-lb`**, Region **South India** → **Review + create**.

### Step 2 — Virtual network (two subnets)

1. In **`rg-appservice-lb`** → **Create** → **Virtual network**.
2. Name **`vnet-task08`**, Address space **`10.10.0.0/16`**.
3. Add subnets:
   - **`subnet-appgw`**: **`10.10.1.0/24`** (Application Gateway only — no other resources in this subnet)
   - **`subnet-appservice`**: **`10.10.2.0/24`** (App Service VNet integration)
4. **Create**.

> App Gateway subnet must be at least **/26** (64 addresses). `/24` is fine.

Optional before Step 4: open **`subnet-appservice`** → **Subnet delegation** → **Microsoft.Web/serverFarms** if VNet integration fails later.

### Step 3 — App Service plan + web app (networking blade)

1. **Create a resource** → **Web App**.
2. Resource group **`rg-appservice-lb`**, Name **`app-task08-<unique>`** (globally unique).
3. **Publish**: Code, **Runtime stack**: **Node 20 LTS** (or your stack).
4. **Region**: South India → **App Service Plan**: **Create new** → **`plan-task08`**, **Pricing**: **Standard S1** (Linux).
5. Open the **Networking** (or **Network** / **Enable virtual network integration**) section on the create blade.

**Use these settings for this lab** (matches the CLI — App Gateway + access restrictions, **not** App Service private endpoint):

| Portal option | Setting | Why |
|---------------|---------|-----|
| **Enable public access** | **On** | App Gateway reaches the app via `*.azurewebsites.net`. Step 8 blocks direct internet bypass with **access restrictions**, not by turning public access off. |
| **Enable virtual network integration** (top-level, if shown) | **On** | Same region VNet: **`vnet-task08`**. |
| **Inbound — Enable private endpoints** | **Off** | Private endpoint = different design. This lab uses **Application Gateway** + allow **`subnet-appgw`** in Step 8. |
| **Inbound — subnet** (only if private endpoints On) | — | Leave unset when private endpoints are **Off**. |
| **Outbound — Enable VNet integration** | **On** | Subnet **`subnet-appservice`** (outbound / integration subnet). |
| **Outbound — subnet** | **`subnet-appservice`** | NSG/routes on this subnet affect **outbound** from the app, not where users connect. |

> **Do not confuse:** **`subnet-appservice`** = outbound VNet integration. **`subnet-appgw`** = where Application Gateway lives; you allow **that** subnet in Step 8 so only the gateway can reach the app.

6. **Review + create**.
7. After deploy, open `https://<app-name>.azurewebsites.net` — expect **200** (before Step 8 restrictions).

### Step 4 — VNet integration (if not set at create)

Skip if you already enabled **Outbound — VNet integration** → **`subnet-appservice`** in Step 3.

1. **Web App** → **Networking**.
2. **Outbound traffic** → **Virtual network integration** → **Add** / **Not configured**.
3. **`vnet-task08`** + **`subnet-appservice`** → **Apply**.
4. Wait until connected.

Verify: **Networking** shows integration to **`subnet-appservice`**.

### Step 5 — Public IP for Application Gateway

1. **Create a resource** → **Public IP address**.
2. Name **`pip-appgw`**, SKU **Standard**, Assignment **Static**, RG **`rg-appservice-lb`**, Region **South India**.
3. **Create**. Note the **IP address** from **Overview**.

### Step 6 — Application Gateway (v2)

1. **Create a resource** → **Application Gateway**.
2. **Basics**:
   - Name **`appgw-task08`**, Region **South India**, RG **`rg-appservice-lb`**
   - **Tier**: **Standard V2** (not WAF v2 for this lab)
   - **Enable autoscaling**: Off (lab) — instance count **1**
   - **Virtual network**: **`vnet-task08`**, Subnet **`subnet-appgw`**
   - **Public IP**: **Existing** → **`pip-appgw`**
3. **Frontends**: Listener — **HTTP**, Port **80** (HTTPS on listener is optional extension).
4. **Backends**:
   - **Backend pool**: Add **FQDN** / hostname → **`<your-app-name>.azurewebsites.net`**
   - **Backend settings**: **HTTPS**, Port **443**, **Backend server certificate** / host: use hostname from backend pool (pick host name from backend address).
5. **Configuration**: Routing rule — listener **HTTP:80** → backend pool + backend settings.
6. **Review + create** (deployment ~10–15 minutes).

### Step 7 — Backend health probe

1. Application Gateway → **Backend health** (or **Health probes** under **Settings**).
2. **Add** probe (or edit default):
   - Name **`probe-appservice`**
   - **Protocol**: **HTTPS**
   - **Path**: `/`
   - **Pick host name from backend settings** / backend address: **Yes**
   - Interval **30** s, Timeout **30** s, Unhealthy threshold **3**
3. **Backend settings** → associate this probe with the App Service backend settings.
4. **Backend health** → confirm backend shows **Healthy**.

If **Unhealthy**: confirm backend hostname is `*.azurewebsites.net`, HTTPS **443**, and access restrictions (Step 8) are not blocking the gateway yet — you may configure probe before Step 8, then add restrictions.

### Step 8 — Lock App Service (allow only App Gateway subnet)

1. **Web App** → **Networking** → **Access restriction** (or **Networking** → **Inbound traffic** → **Access restriction**).
2. **+ Add rule**:
   - **Rule name**: **`allow-appgw-subnet`**
   - **Priority**: **100**
   - **Action**: **Allow**
   - **Type**: **Virtual Network**
   - **Subscription / VNet / Subnet**: **`vnet-task08`** / **`subnet-appgw`**
3. Ensure **Unmatched rule action** (default) is **Deny** for main site.
4. Enable **Use same restrictions for scm site** (Kudu/SCM) if offered → **Save**.

Verify: rule list shows **Allow** for **`subnet-appgw`**; default **Deny** for everything else.

### Step 9 — Test end-to-end

**Via Application Gateway (should work)**

1. Browser or `curl -I http://<pip-appgw-public-ip>/`
2. Expect **HTTP 200**.

**Direct App Service (should be blocked)**

1. `curl -I https://<app-name>.azurewebsites.net/`
2. Expect **403 Forbidden** — App Gateway path is the only allowed inbound route.

---

## Cleanup (Portal)

1. **Resource groups** → **`rg-appservice-lb`** → **Delete resource group**.
2. Confirm deletion (removes App Service, plan, VNet, Application Gateway, public IP).

---

## Path B — Azure Portal — Manual Steps (secure)

**Private Link + Application Gateway:** App Service **public access Off**, inbound only via **private endpoint**, exposed to the Internet **only** through AGW.

### B1 — Virtual network (three subnets)

1. **Resource groups** → **`rg-appservice-lb`** (South India).
2. **Virtual network** **`vnet-task08`**, address space **`10.10.0.0/16`**.
3. Subnets:

| Subnet | CIDR | Purpose |
|--------|------|---------|
| **`subnet-appgw`** | `10.10.1.0/24` | Application Gateway only (dedicated) |
| **`subnet-appservice`** | `10.10.2.0/24` | Outbound VNet integration — delegate **`Microsoft.Web/serverFarms`** |
| **`subnet-pe-app`** | `10.10.3.0/24` | Inbound private endpoint for the web app |

4. Open **`subnet-pe-app`** → **Private endpoint network policy** → **Disabled** → **Save**.

### B2 — Create web app (networking on create blade)

1. **Web App** → **`app-task08-<unique>`**, plan **`plan-task08`**, **Standard S1** Linux, **Node 20 LTS**.
2. **Networking** section — use **exactly**:

| Portal option | Setting |
|---------------|---------|
| **Enable public access** | **Off** |
| **Enable virtual network integration** | **On** → VNet **`vnet-task08`** |
| **Inbound — Enable private endpoints** | **On** |
| **Inbound — Subnet** | **`subnet-pe-app`** |
| **Outbound — Enable VNet integration** | **On** |
| **Outbound — Subnet** | **`subnet-appservice`** |

3. If the wizard offers **Integrate with private DNS zone** → **Yes** → zone **`privatelink.azurewebsites.net`** (creates zone + VNet link + A record).
4. **Review + create**.

> If the app was already created with public access **On**, skip to B3–B4 after create.

### B3 — Private endpoint (if not created at deploy)

1. **Web App** → **Networking** → **Inbound traffic** → **Private endpoints** → **+ Add**.
2. Name **`pe-app-task08`**, VNet **`vnet-task08`**, subnet **`subnet-pe-app`**, sub-resource **sites**.
3. **Integrate with private DNS zone** → **Yes** → **`privatelink.azurewebsites.net`**.
4. Wait until connection status **Approved**. Note **Private IP** (e.g. `10.10.3.5`).

**Manual DNS** (only if integration was **No**):

1. **Private DNS zones** → **`privatelink.azurewebsites.net`** → **+ Record set** → Type **A**, name = **`<app-name>`** (hostname only), IP = PE private IP.
2. **Virtual network links** → link **`vnet-task08`**, auto-registration **Off**.

Optional SCM/Kudu: zone **`privatelink.scm.azurewebsites.net`** + PE for deployment slots (advanced).

### B4 — Confirm public access is disabled

1. **Web App** → **Networking** → **Public network access** → **Disabled** (or **Settings** → disable public access).
2. Verify: from your laptop, `https://<app-name>.azurewebsites.net` does **not** return a normal **200** (unreachable or blocked).

### B5 — Outbound VNet integration (if not set at create)

1. **Networking** → **Outbound traffic** → **Virtual network integration** → **`subnet-appservice`**.
2. Confirm **`subnet-appservice`** has delegation **Microsoft.Web/serverFarms**.

### B6 — Application Gateway (public entry point)

Same as [Path A Steps 5–7](#step-5--public-ip-for-application-gateway), with these important points:

1. **Public IP** **`pip-appgw`** (Standard, static).
2. **Application Gateway** **`appgw-task08`**, **Standard v2**, subnet **`subnet-appgw`**, public IP **`pip-appgw`**.
3. **Backend pool**: FQDN **`<app-name>.azurewebsites.net`** (not the raw private IP — DNS resolves it inside the VNet).
4. **Backend settings**: **HTTPS**, port **443**, pick host name from backend address / backend pool.
5. **Listener**: HTTP **80** (lab) or HTTPS **443** with certificate (production).
6. **Health probe**: HTTPS `/`, host from backend settings → backend must show **Healthy**.

Path B: **Do not** rely on Path A Step 8 access restrictions — inbound is already private-only.

Optional hardening: **NSG** on **`subnet-pe-app`** allowing inbound **443** only from **`subnet-appgw`** address prefix.

### B7 — Test (Path B)

| Test | Expected |
|------|----------|
| `http://<pip-appgw-ip>/` | **200** — only public entry |
| `https://<app-name>.azurewebsites.net/` from laptop | **Fails** — no public app endpoint |

### Path A vs Path B (portal checklist)

| Item | Path A (lab default) | Path B (secure) |
|------|----------------------|-----------------|
| **Enable public access** | **On** | **Off** |
| **Private endpoints (inbound)** | **Off** | **On** → **`subnet-pe-app`** |
| **VNet integration (outbound)** | **On** → **`subnet-appservice`** | **On** → **`subnet-appservice`** |
| **Private DNS** | Not required | **`privatelink.azurewebsites.net`** required |
| **Access restriction Step 8** | **Required** | **Not required** (optional extra) |
| **Internet entry** | **AGW public IP only** (after Step 8) | **AGW public IP only** |

---

## Cleanup (Portal) — both paths

1. **Resource groups** → **`rg-appservice-lb`** → **Delete resource group**.
