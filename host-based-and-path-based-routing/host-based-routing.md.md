# Azure Application Gateway Lab — 2 VMs, 4 Sites + Wildcard
### Domain: `abhijeetrajput.life` | VM1: www + wildcard | VM2: blog + shop

> **Prerequisites:** Run `00-foundation-and-vnet.md` completely (Steps 0–10) before starting here.
> This lab reuses the resource group, VNet, and subnets created there.

---

## Architecture

```
Internet
    │
    ▼
DNS: *.abhijeetrajput.life  →  AGW Public IP (pip-agw)
    │
    ▼
┌──────────────────────────────────────────────────────────┐
│              Azure Application Gateway (AGW)              │
│                                                           │
│  Listener: www.abhijeetrajput.life  (priority 100) ───────┼──► pool-www      (VM1:3001)
│  Listener: blog.abhijeetrajput.life (priority 200) ───────┼──► pool-blog     (VM2:3002)
│  Listener: shop.abhijeetrajput.life (priority 300) ───────┼──► pool-shop     (VM2:3003)
│  Listener: *.abhijeetrajput.life    (priority 400) ───────┼──► pool-wildcard (VM1:3004)
└──────────────────────────────────────────────────────────┘
               │                          │
               ▼                          ▼
     ┌─────────────────┐        ┌─────────────────┐
     │      VM1        │        │      VM2        │
     │  10.10.2.4      │        │  10.10.2.5      │
     │                 │        │                 │
     │  :3001 → www    │        │  :3002 → blog   │
     │  :3004 → wild   │        │  :3003 → shop   │
     └─────────────────┘        └─────────────────┘
```

---

## Resource Plan

| Resource | Name |
|---|---|
| Resource Group | `rg-task01` ← from foundation |
| Virtual Network | `vnet-task01` — 10.10.0.0/16 ← from foundation |
| AGW Subnet | `subnet-agw` — 10.10.1.0/24 ← from foundation |
| Backend Subnet | `subnet-backend` — 10.10.2.0/24 ← from foundation |
| Application Gateway | `agw-abhijeet` (Standard V2) |
| Public IP | `pip-agw` |
| VM 1 | `vm1` — runs www (:3001) + wildcard (:3004) |
| VM 2 | `vm2` — runs blog (:3002) + shop (:3003) |

---

## PRE-STEP — Set environment variables

Run at the start of every session (matches foundation variables):

```bash
RESOURCE_GROUP="rg-task01"
VNET_NAME="vnet-task01"
LOCATION="southindia"

echo "Resource Group: $RESOURCE_GROUP"
echo "VNet          : $VNET_NAME"
```

---

## PRE-STEP — Ensure internet access for VMs (TEMP route)

The foundation's `rt-backend` currently routes all internet traffic to `10.10.9.4` (the future firewall, which doesn't exist yet). VMs need internet access to install Node.js. Make sure the TEMP direct-internet route is active — from foundation Step 8a:

```bash
# Check current 0.0.0.0/0 route
az network route-table route list \
  --resource-group $RESOURCE_GROUP \
  --route-table-name rt-backend \
  --query "[].{Name:name, Prefix:addressPrefix, NextHop:nextHopType}" \
  -o table

# If route-internet-direct-TEMP is NOT listed, add it now:
az network route-table route delete \
  --resource-group $RESOURCE_GROUP \
  --route-table-name rt-backend \
  --name route-internet-via-fw 2>/dev/null || true

az network route-table route create \
  --resource-group $RESOURCE_GROUP \
  --route-table-name rt-backend \
  --name route-internet-direct-TEMP \
  --address-prefix 0.0.0.0/0 \
  --next-hop-type Internet
```

---

## PHASE 1 — Networking already done ✅

The foundation already created:
- `vnet-task01` (10.10.0.0/16)
- `subnet-agw` (10.10.1.0/24) — no route table, ready for AGW
- `subnet-backend` (10.10.2.0/24) — with `rt-backend` attached

**Skip VNet/subnet creation. Go directly to Phase 2.**

---

## PHASE 2 — Create 2 VMs (No Public IP)

Set your password once — both VMs will use it:

```bash
VM_PASSWORD="YourPassword123!"
# Rules: 12–72 chars, must include uppercase + lowercase + digit + special character
# Avoid @ and " in the password — they break shell argument parsing
```

```bash
# VM1 — will host www + wildcard
az vm create \
  --resource-group $RESOURCE_GROUP \
  --name vm1 \
  --image Ubuntu2204 \
  --vnet-name $VNET_NAME \
  --subnet subnet-backend \
  --public-ip-address "" \
  --admin-username azureuser \
  --authentication-type password \
  --admin-password $VM_PASSWORD \
  --size Standard_B2ts_v2

# VM2 — will host blog + shop
az vm create \
  --resource-group $RESOURCE_GROUP \
  --name vm2 \
  --image Ubuntu2204 \
  --vnet-name $VNET_NAME \
  --subnet subnet-backend \
  --public-ip-address "" \
  --admin-username azureuser \
  --authentication-type password \
  --admin-password $VM_PASSWORD \
  --size Standard_B2ts_v2
```

Get their private IPs:

```bash
az vm list-ip-addresses --resource-group $RESOURCE_GROUP --output table

# Save to variables
VM1_IP=$(az vm list-ip-addresses --resource-group $RESOURCE_GROUP --name vm1 \
  --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv)
VM2_IP=$(az vm list-ip-addresses --resource-group $RESOURCE_GROUP --name vm2 \
  --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv)

echo "VM1 IP: $VM1_IP"
echo "VM2 IP: $VM2_IP"
```

> ⚠️ IPs are DHCP-assigned. Yours may differ from 10.10.2.4/10.10.2.5 — use the actual values everywhere below.

---

## PHASE 3 — Setup Apps on Both VMs

VMs have no public IP. Connect via **Serial Console** (free, no setup) or **Azure Bastion**.

**Serial Console:** Portal → vm1 → Help → Serial Console → login with `azureuser` / your password

### VM1 — Install Node.js + Run 2 Apps (:3001 www, :3004 wildcard)

```bash
# Install Node.js + PM2
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt install -y nodejs
sudo npm install -g pm2

# App 1 — www (port 3001)
mkdir -p ~/apps/www && cat << 'EOF' > ~/apps/www/app.js
const http = require('http');
http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, {'Content-Type': 'application/json'});
    res.end(JSON.stringify({ status: 'healthy', app: 'www', port: 3001 }));
    return;
  }
  res.writeHead(200, {'Content-Type': 'text/html'});
  res.end(`<html><body style="font-family:sans-serif;padding:40px;background:#e8f5e9">
    <h1>🏠 Main Site</h1><h2>www.abhijeetrajput.life</h2>
    <p>VM1 | Port 3001</p><p>Host: <b>${req.headers.host}</b></p>
  </body></html>`);
}).listen(3001, () => console.log('www on :3001'));
EOF

# App 4 — wildcard (port 3004)
mkdir -p ~/apps/wildcard && cat << 'EOF' > ~/apps/wildcard/app.js
const http = require('http');
http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, {'Content-Type': 'application/json'});
    res.end(JSON.stringify({ status: 'healthy', app: 'wildcard', port: 3004 }));
    return;
  }
  res.writeHead(200, {'Content-Type': 'text/html'});
  res.end(`<html><body style="font-family:sans-serif;padding:40px;background:#f3e5f5">
    <h1>🌐 Wildcard Catch-All</h1><h2>*.abhijeetrajput.life</h2>
    <p>VM1 | Port 3004</p><p>You hit: <b>${req.headers.host}</b></p>
  </body></html>`);
}).listen(3004, () => console.log('wildcard on :3004'));
EOF

pm2 start ~/apps/www/app.js      --name "www-3001"
pm2 start ~/apps/wildcard/app.js --name "wildcard-3004"
pm2 save && pm2 startup

# Verify
curl http://localhost:3001/health
curl http://localhost:3004/health
```

### VM2 — Install Node.js + Run 2 Apps (:3002 blog, :3003 shop)

```bash
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt install -y nodejs
sudo npm install -g pm2

# App 2 — blog (port 3002)
mkdir -p ~/apps/blog && cat << 'EOF' > ~/apps/blog/app.js
const http = require('http');
http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, {'Content-Type': 'application/json'});
    res.end(JSON.stringify({ status: 'healthy', app: 'blog', port: 3002 }));
    return;
  }
  res.writeHead(200, {'Content-Type': 'text/html'});
  res.end(`<html><body style="font-family:sans-serif;padding:40px;background:#e3f2fd">
    <h1>📝 Blog</h1><h2>blog.abhijeetrajput.life</h2>
    <p>VM2 | Port 3002</p><p>Host: <b>${req.headers.host}</b></p>
  </body></html>`);
}).listen(3002, () => console.log('blog on :3002'));
EOF

# App 3 — shop (port 3003)
mkdir -p ~/apps/shop && cat << 'EOF' > ~/apps/shop/app.js
const http = require('http');
http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, {'Content-Type': 'application/json'});
    res.end(JSON.stringify({ status: 'healthy', app: 'shop', port: 3003 }));
    return;
  }
  res.writeHead(200, {'Content-Type': 'text/html'});
  res.end(`<html><body style="font-family:sans-serif;padding:40px;background:#fff3e0">
    <h1>🛒 Shop</h1><h2>shop.abhijeetrajput.life</h2>
    <p>VM2 | Port 3003</p><p>Host: <b>${req.headers.host}</b></p>
  </body></html>`);
}).listen(3003, () => console.log('shop on :3003'));
EOF

pm2 start ~/apps/blog/app.js --name "blog-3002"
pm2 start ~/apps/shop/app.js --name "shop-3003"
pm2 save && pm2 startup

# Verify
curl http://localhost:3002/health
curl http://localhost:3003/health
```

---

## PHASE 4 — NSG: Allow AGW → VMs

```bash
az network nsg create \
  --resource-group $RESOURCE_GROUP \
  --name nsg-backend

az network nsg rule create \
  --resource-group $RESOURCE_GROUP \
  --nsg-name nsg-backend \
  --name allow-apps-from-agw \
  --priority 100 \
  --source-address-prefixes 10.10.1.0/24 \
  --destination-port-ranges 3001 3002 3003 3004 \
  --protocol Tcp --access Allow

# Required by Azure for AGW health probes — do not skip
az network nsg rule create \
  --resource-group $RESOURCE_GROUP \
  --nsg-name nsg-backend \
  --name allow-agw-healthprobe \
  --priority 110 \
  --source-address-prefixes GatewayManager \
  --destination-port-ranges 65200-65535 \
  --protocol Tcp --access Allow

az network vnet subnet update \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name subnet-backend \
  --network-security-group nsg-backend
```

---

## PHASE 5 — Create Application Gateway

### 5.1 Public IP

```bash
az network public-ip create \
  --resource-group $RESOURCE_GROUP \
  --name pip-agw \
  --sku Standard \
  --allocation-method Static

AGW_IP=$(az network public-ip show \
  --resource-group $RESOURCE_GROUP \
  --name pip-agw \
  --query ipAddress -o tsv)

echo "AGW Public IP: $AGW_IP"
```

### 5.2 Create AGW (Portal)

**Portal → Create Resource → Application Gateway**

#### Basics Tab
| Field | Value |
|---|---|
| Resource Group | `rg-task01` |
| Name | `agw-abhijeet` |
| Region | South India |
| Tier | Standard V2 |
| Autoscaling | Yes, min: 0, max: 2 |
| Virtual network | `vnet-task01` |
| Subnet | `subnet-agw` |

#### Frontends Tab
| Field | Value |
|---|---|
| Frontend IP type | Public |
| Public IP | `pip-agw` |

#### Backends Tab — Add 4 Pools

| Pool Name | IP |
|---|---|
| `pool-www` | VM1 IP (`10.10.2.4`) |
| `pool-wildcard` | VM1 IP (`10.10.2.4`) |
| `pool-blog` | VM2 IP (`10.10.2.5`) |
| `pool-shop` | VM2 IP (`10.10.2.5`) |

#### Configuration Tab — 4 Backend Settings

| Setting Name | Protocol | Port |
|---|---|---|
| `setting-www` | HTTP | `3001` |
| `setting-blog` | HTTP | `3002` |
| `setting-shop` | HTTP | `3003` |
| `setting-wildcard` | HTTP | `3004` |

#### Configuration Tab — 4 Routing Rules

| Rule | Priority | Listener | Host type | Hostname | Pool | Setting |
|---|---|---|---|---|---|---|
| `rule-www` | 100 | `listener-www` | Single | `www.abhijeetrajput.life` | `pool-www` | `setting-www` |
| `rule-blog` | 200 | `listener-blog` | Single | `blog.abhijeetrajput.life` | `pool-blog` | `setting-blog` |
| `rule-shop` | 300 | `listener-shop` | Single | `shop.abhijeetrajput.life` | `pool-shop` | `setting-shop` |
| `rule-wildcard` | 400 | `listener-wildcard` | **Multiple/Wildcard** | `*.abhijeetrajput.life` | `pool-wildcard` | `setting-wildcard` |

Click **Review + Create → Create** — takes 5–7 minutes.

---

## PHASE 6 — DNS Records

Add in your DNS provider (all pointing to same AGW IP):

| Type | Name | Value |
|------|------|-------|
| A | `@` | `<AGW_IP>` |
| A | `www` | `<AGW_IP>` |
| A | `blog` | `<AGW_IP>` |
| A | `shop` | `<AGW_IP>` |
| A | `*` | `<AGW_IP>` |

---

## PHASE 7 — Test

### 7.1 Backend Health Check

> ⚠️ `--output table` returns blank for this command. Always use the query form:

```bash
az network application-gateway show-backend-health \
  --resource-group $RESOURCE_GROUP \
  --name agw-abhijeet \
  --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].{Address:address, Health:health}" \
  --output table
```

All 4 entries must show `Healthy` before testing from browser.

### 7.2 curl Tests

```bash
curl http://www.abhijeetrajput.life    # → 🏠 Main Site | VM1:3001
curl http://blog.abhijeetrajput.life   # → 📝 Blog | VM2:3002
curl http://shop.abhijeetrajput.life   # → 🛒 Shop | VM2:3003
curl http://test.abhijeetrajput.life   # → 🌐 Wildcard | VM1:3004
```

---

## PHASE 8 — Custom Health Probes

### Why

Default probe hits `/` every 30s. Custom probe hits `/health` every 15s — faster failure detection.

> **Why `--host <VM_IP>`:** CLI creates probes with `PickHostNameFromBackendHttpSettings=true` by default which causes `ApplicationGatewayBackendHttpSettingsIncompatibleProbeSettingPickHostName` error on attach. Using explicit `--host` avoids this.

### 8.1 Create Probes

```bash
az network application-gateway probe create \
  --resource-group $RESOURCE_GROUP \
  --gateway-name agw-abhijeet \
  --name probe-www \
  --protocol Http --path /health \
  --interval 15 --timeout 10 --threshold 3 \
  --port 3001 --host 10.10.2.4 \
  --match-status-codes 200-399
```

Repeat for remaining probes:

| `--name` | `--port` | `--host` |
|---|---|---|
| `probe-blog` | `3002` | `10.10.2.5` |
| `probe-shop` | `3003` | `10.10.2.5` |
| `probe-wildcard` | `3004` | `10.10.2.4` |

Verify:

```bash
az network application-gateway probe list \
  --resource-group $RESOURCE_GROUP \
  --gateway-name agw-abhijeet \
  --query "[].{Name:name, Host:host, Path:path, Port:port}" \
  --output table
```

### 8.2 Attach Probes to Backend Settings

`--probe` requires full resource ID, not just the name. Pattern for each:

```bash
PROBE_ID=$(az network application-gateway show \
  --resource-group $RESOURCE_GROUP \
  --name agw-abhijeet \
  --query "probes[?name=='probe-www'].id" -o tsv)

az network application-gateway http-settings update \
  --resource-group $RESOURCE_GROUP \
  --gateway-name agw-abhijeet \
  --name setting-www \
  --probe $PROBE_ID
```

Repeat changing probe name and setting name:

| probe name | setting name |
|---|---|
| `probe-blog` | `setting-blog` |
| `probe-shop` | `setting-shop` |
| `probe-wildcard` | `setting-wildcard` |

### 8.3 Verify

```bash
# Confirm probes attached (no nulls)
az network application-gateway show \
  --resource-group $RESOURCE_GROUP \
  --name agw-abhijeet \
  --query "backendHttpSettingsCollection[].{Setting:name, Port:port, Probe:probe.id}" \
  --output table

# Confirm still healthy
az network application-gateway show-backend-health \
  --resource-group $RESOURCE_GROUP \
  --name agw-abhijeet \
  --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].{Address:address, Health:health}" \
  --output table
```

---

## PHASE 9 — HTTP → HTTPS Redirect

### What we're building

```
TODAY:
http://www  → listener-www (port 80) → pool-www → VM

AFTER 9.4–9.6:
http://www  → listener-www (port 80) → REDIRECT → https://www
https://www → listener-www-https (port 443) → pool-www → VM
```

### 9.1 — Get SSL Certificate

> Set TTL to `60` on `_acme-challenge` in your DNS provider before running certbot.

```bash
sudo apt install certbot -y

sudo certbot certonly \
  --manual \
  --preferred-challenges dns \
  -d "abhijeetrajput.life" \
  -d "*.abhijeetrajput.life"
```

Certbot pauses and prints:
```
Please deploy a DNS TXT record under the name:
_acme-challenge.abhijeetrajput.life
with the following value:
<SOME_VALUE>

Press Enter to Continue
```

**Do NOT press Enter yet.**

Add in DNS provider:

| Type | Name | Value | TTL |
|------|------|-------|-----|
| TXT | `_acme-challenge` | `<value certbot printed>` | 60 |

Wait ~2 min, verify propagation, then press Enter:

```bash
dig TXT _acme-challenge.abhijeetrajput.life @8.8.8.8 +short
dig TXT _acme-challenge.abhijeetrajput.life @1.1.1.1 +short
# Both must return the certbot value before pressing Enter
```

Convert cert to PFX (AGW requires PFX):

```bash
sudo ls /etc/letsencrypt/live/abhijeetrajput.life/
# Must show: cert.pem  chain.pem  fullchain.pem  privkey.pem

sudo openssl pkcs12 -export \
  -out wildcard-abhijeetrajput.pfx \
  -inkey /etc/letsencrypt/live/abhijeetrajput.life/privkey.pem \
  -in /etc/letsencrypt/live/abhijeetrajput.life/fullchain.pem \
  -passout pass:LabPassword123

openssl pkcs12 -in wildcard-abhijeetrajput.pfx \
  -passin pass:LabPassword123 -noout
# No output = valid
```

> Re-run certbot if it fails — it generates a **new** value each time. Never reuse old value.

---

### 9.2 — Check actual frontend names in your AGW

> Names vary depending on whether AGW was created via Portal or CLI.

```bash
az network application-gateway show \
  --resource-group $RESOURCE_GROUP --name agw-abhijeet \
  --query "frontendPorts[].{Name:name, Port:port}" --output table

az network application-gateway show \
  --resource-group $RESOURCE_GROUP --name agw-abhijeet \
  --query "frontendIPConfigurations[].name" --output table
```

Set variables from the output:

```bash
FRONTEND_PORT="port_443"                    # exact name from above
FRONTEND_IP="appGwPublicFrontendIpIPv4"     # exact name from above
```

If port 443 is not listed, create it:

```bash
az network application-gateway frontend-port create \
  --gateway-name agw-abhijeet --resource-group $RESOURCE_GROUP \
  --name port_443 --port 443
```

---

### 9.3 — Upload SSL cert to AGW

> **Portal only:** cert is uploaded while creating the first HTTPS listener in 9.4. No separate upload page exists in the Portal — skip to 9.4 if using Portal.

**CLI:**

```bash
az network application-gateway ssl-cert create \
  --gateway-name agw-abhijeet --resource-group $RESOURCE_GROUP \
  --name wildcard-cert \
  --cert-file wildcard-abhijeetrajput.pfx \
  --cert-password LabPassword123
```

---

### 9.4 — Create HTTPS listeners (port 443 entry points)

> **Goal:** AGW can now receive HTTPS traffic on port 443 with your wildcard cert. One listener per site.

**CLI:**

```bash
az network application-gateway http-listener create \
  --gateway-name agw-abhijeet --resource-group $RESOURCE_GROUP \
  --name listener-www-https \
  --frontend-port $FRONTEND_PORT \
  --frontend-ip $FRONTEND_IP \
  --ssl-cert wildcard-cert \
  --host-name www.abhijeetrajput.life
```

Repeat for remaining listeners (change `--name` and `--host-name`):

| `--name` | `--host-name` |
|---|---|
| `listener-blog-https` | `blog.abhijeetrajput.life` |
| `listener-shop-https` | `shop.abhijeetrajput.life` |
| `listener-wildcard-https` | `*.abhijeetrajput.life` ← use `--host-names` (plural) |

**Portal:** Portal → `agw-abhijeet` → Settings → Listeners → + Add listener (repeat 4 times):

| Listener name | Protocol | Port | Certificate | Listener type | Host type | Host name |
|---|---|---|---|---|---|---|
| `listener-www-https` | HTTPS | 443 | Upload → `wildcard-cert` | Multi site | Single | `www.abhijeetrajput.life` |
| `listener-blog-https` | HTTPS | 443 | Select `wildcard-cert` | Multi site | Single | `blog.abhijeetrajput.life` |
| `listener-shop-https` | HTTPS | 443 | Select `wildcard-cert` | Multi site | Single | `shop.abhijeetrajput.life` |
| `listener-wildcard-https` | HTTPS | 443 | Select `wildcard-cert` | Multi site | **Multiple/Wildcard** | `*.abhijeetrajput.life` |

---

### 9.5 + 9.6 — Attach redirect to HTTP rules (Portal)

> **Goal:** Port 80 stops forwarding to backends and starts redirecting to HTTPS instead.
> The Portal combines both steps in one action — no separate redirect config creation needed.

**Portal → `agw-abhijeet` → Settings → Rules → click `rule-www`**

1. Click the **Backend targets** tab
2. Change **Target type** from `Backend pool` → **Redirection**
3. Fill in:

| Field | Value |
|---|---|
| Redirection type | Permanent |
| Redirection target | Listener |
| Target listener | `listener-www-https` |
| Include path | Yes |
| Include query string | Yes |

4. Click **Save**

Repeat for the remaining 3 rules:

| Rule to edit | Target listener |
|---|---|
| `rule-blog` | `listener-blog-https` |
| `rule-shop` | `listener-shop-https` |
| `rule-wildcard` | `listener-wildcard-https` |

> After saving each rule you'll see its action change from `Backend pool` to `Redirect` in the Rules list — that confirms port 80 is now redirecting for that site.

---

### 9.7 — Create HTTPS routing rules (port 443 forwards to backends)

> **Goal:** Port 443 needs its own routing rules to forward traffic to backend pools. Without these, HTTPS hits the listener but goes nowhere.

```bash
az network application-gateway rule create \
  --gateway-name agw-abhijeet --resource-group $RESOURCE_GROUP \
  --name rule-www-https --priority 110 \
  --http-listener listener-www-https \
  --address-pool pool-www \
  --http-settings setting-www
```

Repeat (change all 5 values):

| `--name` | `--priority` | `--http-listener` | `--address-pool` | `--http-settings` |
|---|---|---|---|---|
| `rule-blog-https` | `210` | `listener-blog-https` | `pool-blog` | `setting-blog` |
| `rule-shop-https` | `310` | `listener-shop-https` | `pool-shop` | `setting-shop` |
| `rule-wildcard-https` | `410` | `listener-wildcard-https` | `pool-wildcard` | `setting-wildcard` |

---

### 9.8 — Test

```bash
# Must return 301 redirect
curl -v http://www.abhijeetrajput.life 2>&1 | grep -E "HTTP|Location"
# Expected:
# HTTP/1.1 301 Moved Permanently
# Location: https://www.abhijeetrajput.life/

# Follow redirect all the way to backend
curl -Lv https://www.abhijeetrajput.life
# Expected: 200 OK with HTML from VM1
```

---

## PHASE 10 — SSL Termination at AGW

### What is SSL Termination?

```
WITHOUT termination:
Client ──HTTPS──► AGW ──HTTPS──► Backend VM   (VM needs cert too)

WITH termination (what we have):
Client ──HTTPS──► AGW ──HTTP──► Backend VM    (VM only needs HTTP)
                  ↑
          AGW decrypts here, backend sees plain HTTP
```

SSL termination is already working from Phase 9. The HTTPS listeners decrypt at AGW then forward plain HTTP to ports 3001–3004. VMs never need SSL configured.

### Verify

```bash
# TLS handshake happens with AGW cert
curl -v https://www.abhijeetrajput.life

# From inside VM — AGW sends plain HTTP to backend
pm2 logs www-3001 --lines 5
# → GET / HTTP/1.1  ← plain HTTP confirms SSL terminated at AGW
```

---

## Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| Backend unhealthy | App not running | SSH → `pm2 status` |
| Backend unhealthy | NSG blocking | Allow 3001-3004 from `10.10.1.0/24` |
| Backend unhealthy | AGW probe port blocked | Allow 65200-65535 from GatewayManager |
| 502 Bad Gateway | Wrong port in backend setting | Portal → AGW → Backend settings → check port |
| `IncompatibleProbeSettingPickHostName` | Probe uses pick-host-from-backend | Delete probe, recreate with `--host <VM_IP>` |
| Probe attach returns empty PROBE_ID | Probe not created | Run `probe list` to verify |
| Certbot "Incorrect TXT record" | Pressed Enter before propagation | Re-run certbot, verify with `dig` first |
| `InvalidResourceReference` on listener | Wrong frontend port/IP name | Run the 9.2 check commands, use exact names |
| HTTP not redirecting after 9.5+9.6 | Rule still shows Backend pool | Portal → Rules → edit rule → change Target type to Redirection |
| HTTPS cert error | Cert CN mismatch | Cert must cover `*.abhijeetrajput.life` |
| curl works, browser shows cert warning | Self-signed cert | Use proper Let's Encrypt cert |

---

## Cleanup

> ⚠️ Deletes entire `rg-task01` including foundation resources. Only run when done with all tasks.

```bash
az group delete --name $RESOURCE_GROUP --yes --no-wait
```

To clean up only this lab's resources:

```bash
az network application-gateway delete --name agw-abhijeet --resource-group $RESOURCE_GROUP --no-wait
az network public-ip delete --name pip-agw --resource-group $RESOURCE_GROUP
az vm delete --name vm1 --resource-group $RESOURCE_GROUP --yes --no-wait
az vm delete --name vm2 --resource-group $RESOURCE_GROUP --yes --no-wait
az network nsg delete --name nsg-backend --resource-group $RESOURCE_GROUP
```
