# Public VM vs Private VM — Internet Access Demo + App Gateway Expose

> **Goal:** Prove with real VMs why `ping 8.8.8.8` works on a public VM and fails on a private VM.
> Then deploy a Node.js app on the private VM and expose it safely to the internet via
> an Application Gateway (L7 load balancer).
> Uses the VNet and subnets from `00-foundation-setup.md` — run that first.

---

## What you will build

```
PART 1–5: Public vs Private VM

subnet-agw (10.10.1.0/24)              subnet-backend (10.10.2.0/24)
┌──────────────────────────┐            ┌────────────────────────────────┐
│  vm-public               │            │  vm-private                    │
│  Public IP : 20.x.x.x   │            │  Public IP : NONE              │
│  Private IP: 10.10.1.x   │            │  Private IP: 10.10.2.x         │
│  NSG: allow SSH (22)     │            │  NSG: allow SSH from VNet only │
│  Route: default system   │            │  Route: 0.0.0.0/0 → None       │
│         0.0.0.0/0→Internet│           │         (blackhole)            │
└──────────┬───────────────┘            └──────────────┬─────────────────┘
           │                                           │
           │ ping 8.8.8.8 ✅ WORKS                    │ ping 8.8.8.8 ❌ DROPS
           ▼                                           ▼
      PUBLIC INTERNET                          BLACKHOLE (Next hop: None)


PART 6: Expose private VM app via Application Gateway

INTERNET
    │  HTTP :80
    ▼
┌──────────────────────────────────────┐
│  Application Gateway  (subnet-agw2)  │
│  10.10.3.0/24 — dedicated AGW subnet │
│  Public IP: 20.x.x.x                │
│  Listener → / → Backend Pool        │
│  Health probe → GET /health → :3001  │
└──────────────────┬───────────────────┘
                   │ HTTP :3001 (VNet only)
                   ▼
        ┌──────────────────────────┐
        │  vm-private (subnet-backend) │
        │  Node.js app on port 3001    │
        │  NO public IP                │
        └──────────────────────────────┘

NOTE: AGW V2 requires a dedicated subnet with no other resources.
      vm-public lives in subnet-agw (10.10.1.0/24).
      AGW lives in subnet-agw2 (10.10.3.0/24).
```

---

## Environment variables

Run these at the start of every session — all commands below reference them.

```bash
RESOURCE_GROUP="rg-task01"
VNET_NAME="vnet-task01"
LOCATION="southindia"
```

---

## Step 0 — Create Resource Group, VNet and Subnets

> Skip if you already ran `00-foundation-setup.md` — these resources will already exist.

```bash
# Create resource group
az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION

# Create VNet
az network vnet create \
  --resource-group $RESOURCE_GROUP \
  --name $VNET_NAME \
  --location $LOCATION \
  --address-prefixes 10.10.0.0/16

# Subnet for vm-public
az network vnet subnet create \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name subnet-agw \
  --address-prefixes 10.10.1.0/24

# Subnet for private VM (backend)
az network vnet subnet create \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name subnet-backend \
  --address-prefixes 10.10.2.0/24

# Subnet for Application Gateway (dedicated — AGW V2 cannot share subnet with other resources)
az network vnet subnet create \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name subnet-agw2 \
  --address-prefixes 10.10.3.0/24
```

---

## Part 1 — Create the PUBLIC VM

### Step 1 — NSG for public VM (allow SSH from internet)

```bash
az network nsg create \
  --resource-group $RESOURCE_GROUP \
  --name nsg-public-vm \
  --location $LOCATION

az network nsg rule create \
  --resource-group $RESOURCE_GROUP \
  --nsg-name nsg-public-vm \
  --name allow-ssh \
  --priority 100 \
  --source-address-prefixes Internet \
  --destination-port-ranges 22 \
  --protocol TCP \
  --access Allow \
  --direction Inbound
```

### Step 2 — Create vm-public (in subnet-agw, WITH a Public IP)

```bash
az vm create \
  --resource-group $RESOURCE_GROUP \
  --name vm-public \
  --location $LOCATION \
  --image Ubuntu2204 \
  --size Standard_B2ts_v2 \
  --vnet-name $VNET_NAME \
  --subnet subnet-agw \
  --nsg nsg-public-vm \
  --public-ip-address pip-vm-public \
  --public-ip-sku Standard \
  --admin-username azureuser \
  --generate-ssh-keys \
  --no-wait
```

> **What makes this VM "public":**
> - `--public-ip-address pip-vm-public` → Azure creates a public IP and attaches it to the NIC
> - `subnet-agw` has no UDR → Azure's default `0.0.0.0/0 → Internet` route is active
> - NSG allows SSH from `Internet` → you can reach it directly from your laptop

---

## Part 2 — Create the PRIVATE VM

### Step 3 — Route table that blackholes internet traffic

```bash
# Create route table
az network route-table create \
  --resource-group $RESOURCE_GROUP \
  --name rt-private-demo \
  --location $LOCATION \
  --disable-bgp-route-propagation true

# Route 1: VNet traffic stays inside VNet
az network route-table route create \
  --resource-group $RESOURCE_GROUP \
  --route-table-name rt-private-demo \
  --name route-vnet-local \
  --address-prefix 10.10.0.0/16 \
  --next-hop-type VnetLocal

# Route 2: Everything else (internet) → blackhole (silently dropped)
az network route-table route create \
  --resource-group $RESOURCE_GROUP \
  --route-table-name rt-private-demo \
  --name route-block-internet \
  --address-prefix 0.0.0.0/0 \
  --next-hop-type None
```

> **`--next-hop-type None` = blackhole.**
> Any packet matching `0.0.0.0/0` that isn't covered by the more-specific `10.10.0.0/16`
> rule is silently dropped — it never reaches the internet.
> In production you'd use `VirtualAppliance` + Firewall IP instead of `None`.

### Step 4 — NSG for private VM (block all inbound from internet)

```bash
az network nsg create \
  --resource-group $RESOURCE_GROUP \
  --name nsg-private-vm \
  --location $LOCATION

# Allow SSH only from within the VNet (jump via vm-public)
az network nsg rule create \
  --resource-group $RESOURCE_GROUP \
  --nsg-name nsg-private-vm \
  --name allow-ssh-from-vnet \
  --priority 100 \
  --source-address-prefixes VirtualNetwork \
  --destination-port-ranges 22 \
  --protocol TCP \
  --access Allow \
  --direction Inbound

# Explicitly deny anything from internet
az network nsg rule create \
  --resource-group $RESOURCE_GROUP \
  --nsg-name nsg-private-vm \
  --name deny-internet-inbound \
  --priority 200 \
  --source-address-prefixes Internet \
  --destination-port-ranges '*' \
  --protocol '*' \
  --access Deny \
  --direction Inbound
```

### Step 5 — Create vm-private (in subnet-backend, NO Public IP)

```bash
az vm create \
  --resource-group $RESOURCE_GROUP \
  --name vm-private \
  --location $LOCATION \
  --image Ubuntu2204 \
  --size Standard_B2ts_v2 \
  --vnet-name $VNET_NAME \
  --subnet subnet-backend \
  --nsg nsg-private-vm \
  --public-ip-address "" \
  --admin-username azureuser \
  --generate-ssh-keys
```

> **What makes this VM "private":**
> - `--public-ip-address ""` → no public IP, only a private IP from `10.10.2.0/24`
> - `rt-private-demo` will be attached next → `0.0.0.0/0 → None` blocks internet
> - NSG only allows SSH from `VirtualNetwork` → unreachable from the internet directly

### Step 6 — Attach route table to subnet-backend

```bash
az network vnet subnet update \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name subnet-backend \
  --route-table rt-private-demo
```

---

## Part 3 — Test It

### Test A — SSH into vm-public and ping internet

```bash
# Get the public IP of vm-public
PUBLIC_IP=$(az vm show \
  --resource-group $RESOURCE_GROUP \
  --name vm-public \
  --show-details --query publicIps -o tsv)

echo "Connect to: $PUBLIC_IP"

# SSH in
ssh azureuser@$PUBLIC_IP
```

Inside vm-public, run:

```bash
ping -c 4 8.8.8.8
curl -s ifconfig.me
```

**Expected — internet works:**

```
PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data.
64 bytes from 8.8.8.8: icmp_seq=1 ttl=118 time=3.45 ms
64 bytes from 8.8.8.8: icmp_seq=2 ttl=118 time=3.21 ms
64 bytes from 8.8.8.8: icmp_seq=3 ttl=118 time=3.18 ms
64 bytes from 8.8.8.8: icmp_seq=4 ttl=118 time=3.30 ms

--- 8.8.8.8 ping statistics ---
4 packets transmitted, 4 received, 0% packet loss
```

---

### Test B — Jump into vm-private and ping internet

vm-private has no public IP so you cannot SSH into it directly.
Use vm-public as a jump host:

```bash
# On your LOCAL machine — get the private IP of vm-private
PRIVATE_IP=$(az vm show \
  --resource-group $RESOURCE_GROUP \
  --name vm-private \
  --show-details --query privateIps -o tsv)

echo "Private VM IP: $PRIVATE_IP"
```

```bash
# SSH to public VM with agent forwarding (-A), then hop to private VM
ssh -A azureuser@$PUBLIC_IP
# Now inside vm-public:
ssh azureuser@$PRIVATE_IP
```

Inside vm-private, run:

```bash
ping -c 4 8.8.8.8              # internet — should FAIL
curl -s --max-time 5 ifconfig.me   # internet — should timeout
ping -c 4 10.10.1.10           # vm-public's private IP — should WORK (VNet-local)
```

**Expected — internet blocked, VNet works:**

```
# ping 8.8.8.8
PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data.
^C
--- 8.8.8.8 ping statistics ---
4 packets transmitted, 0 received, 100% packet loss   ← BLOCKED ❌

# ping 10.10.1.10 (vm-public inside VNet)
64 bytes from 10.10.1.10: icmp_seq=1 ttl=64 time=1.12 ms
64 bytes from 10.10.1.10: icmp_seq=2 ttl=64 time=0.98 ms   ← WORKS ✅
```

---

## Part 4 — Prove It with Effective Routes (the smoking gun)

Run these from your local machine (not inside the VMs):

```bash
# --- vm-public effective routes ---
PUBLIC_NIC=$(az vm show -g $RESOURCE_GROUP -n vm-public \
  --query "networkProfile.networkInterfaces[0].id" -o tsv | awk -F'/' '{print $NF}')

az network nic show-effective-route-table \
  --resource-group $RESOURCE_GROUP \
  --name $PUBLIC_NIC \
  -o table
```

**vm-public — no UDR, default Azure routing:**

```
Source    State    Prefix              NextHopType    NextHopIP
────────  ───────  ──────────────────  ─────────────  ─────────
Default   Active   10.10.0.0/16        VnetLocal
Default   Active   0.0.0.0/0           Internet       ← untouched, internet works ✅
Default   Active   169.254.169.254/32  Internet
Default   Active   168.63.129.16/32    Internet
```

```bash
# --- vm-private effective routes ---
PRIVATE_NIC=$(az vm show -g $RESOURCE_GROUP -n vm-private \
  --query "networkProfile.networkInterfaces[0].id" -o tsv | awk -F'/' '{print $NF}')

az network nic show-effective-route-table \
  --resource-group $RESOURCE_GROUP \
  --name $PRIVATE_NIC \
  -o table
```

**vm-private — UDR active, internet blackholed:**

```
Source    State    Prefix              NextHopType    NextHopIP
────────  ───────  ──────────────────  ─────────────  ─────────
User      Active   10.10.0.0/16        VnetLocal      ← VNet works ✅
Default   Invalid  0.0.0.0/0           Internet       ← Azure default OVERRIDDEN ❌
User      Active   0.0.0.0/0           None           ← your blackhole, internet DROPPED ❌
Default   Active   169.254.169.254/32  Internet
Default   Active   168.63.129.16/32    Internet
```

> **`Default   Invalid`** on Azure's `0.0.0.0/0 → Internet` means your UDR won.
> The `User   Active   0.0.0.0/0   None` line is exactly what kills internet on the private VM.

**Why VNet traffic still works despite the blackhole:**

```
Traffic to 8.8.8.8   (public) → matches 0.0.0.0/0    → Next hop: None      → DROPPED ❌
Traffic to 10.10.1.10 (VNet)  → matches 10.10.0.0/16 → Next hop: VnetLocal → OK ✅

Azure uses longest-prefix match — 10.10.0.0/16 is more specific than 0.0.0.0/0
so VNet traffic always hits the VnetLocal route before reaching the blackhole.
```

---

## Part 5 — Fix Outbound: Give vm-private Internet via NAT Gateway

vm-private stays private (no inbound from internet) but now gets outbound access via NAT Gateway.

```bash
# Create a public IP for NAT Gateway
az network public-ip create \
  --resource-group $RESOURCE_GROUP \
  --name pip-natgw-demo \
  --location $LOCATION \
  --sku Standard \
  --allocation-method Static

# Create NAT Gateway
az network nat gateway create \
  --resource-group $RESOURCE_GROUP \
  --name natgw-demo \
  --location $LOCATION \
  --public-ip-addresses pip-natgw-demo \
  --idle-timeout 10

# Remove the blackhole route — replace with direct internet (NAT GW handles SNAT)
az network route-table route delete \
  --resource-group $RESOURCE_GROUP \
  --route-table-name rt-private-demo \
  --name route-block-internet

az network route-table route create \
  --resource-group $RESOURCE_GROUP \
  --route-table-name rt-private-demo \
  --name route-internet-via-nat \
  --address-prefix 0.0.0.0/0 \
  --next-hop-type Internet

# Attach NAT Gateway to subnet-backend
az network vnet subnet update \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name subnet-backend \
  --nat-gateway natgw-demo
```

SSH back into vm-private and test again:

```bash
ping -c 4 8.8.8.8       # ✅ Now works — NAT Gateway does SNAT
curl -s ifconfig.me     # ✅ Returns NAT Gateway's public IP — NOT the VM's private IP
```

> **Key point:** vm-private still has NO public IP.
> It cannot be reached from the internet (NSG blocks inbound, no public IP for DNAT).
> But it can now reach out — NAT Gateway does SNAT on its behalf.
> This is exactly what "private subnet with controlled outbound" means.

---

## Part 6 — Deploy App on vm-private + Expose via Application Gateway

Now we put a real Node.js app on vm-private and expose it to the internet
using an Application Gateway — without ever giving vm-private a public IP.

> **Why Application Gateway (L7) and not a basic Load Balancer (L4)?**
>
> | Feature | L4 Azure Load Balancer | L7 Application Gateway |
> |---------|----------------------|------------------------|
> | Routing | IP + Port only | URL path, hostname, headers |
> | SSL termination | ❌ No | ✅ Yes |
> | Health probe | TCP port check | HTTP GET to a path |
> | WAF support | ❌ No | ✅ Yes |
> | Use when | Simple TCP forwarding | HTTP/HTTPS apps |

### Step 7 — Update NSG on vm-private to allow AGW → port 3001

AGW will send HTTP traffic to port 3001 on vm-private. Add that rule now:

```bash
az network nsg rule create \
  --resource-group $RESOURCE_GROUP \
  --nsg-name nsg-private-vm \
  --name allow-agw-to-app \
  --priority 90 \
  --source-address-prefixes 10.10.3.0/24 \
  --destination-port-ranges 3001 \
  --protocol TCP \
  --access Allow \
  --direction Inbound
```

> Priority 90 — evaluated before the existing `allow-ssh-from-vnet` (100) and
> `deny-internet-inbound` (200) rules. Source is `10.10.3.0/24` (subnet-agw2 only) —
> not the whole VNet, not the internet.

### Step 8 — Install Node.js app on vm-private

> vm-private now has outbound internet via NAT Gateway (Part 5) — so `apt install` works.
> SSH in via vm-public as jump host:

```bash
ssh -A azureuser@$PUBLIC_IP
ssh azureuser@$PRIVATE_IP
```

Inside vm-private, run:

```bash
# Install Node.js 18
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt install -y nodejs

# Install pm2 (process manager — keeps app alive after reboot)
sudo npm install -g pm2

# Verify
node --version    # v18.x.x
pm2 --version
```

### Step 9 — Create the Node.js app

```bash
mkdir -p ~/apps/www

cat << 'EOF' > ~/apps/www/app.js
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
```

### Step 10 — Start with pm2 (survives reboots)

```bash
pm2 start ~/apps/www/app.js --name "www-3001"
pm2 save        # save process list so pm2 restores it on reboot
pm2 startup     # copy-paste and run the systemd command pm2 prints

# Verify app is running locally on the VM
curl http://localhost:3001/health
# Expected: {"status":"healthy","app":"www","port":3001}

curl http://localhost:3001
# Expected: HTML page "Main Site"
```

**pm2 quick reference:**

```bash
pm2 list                  # show all running apps and their status
pm2 logs www-3001         # tail logs
pm2 restart www-3001      # restart without downtime
pm2 stop www-3001         # stop (keeps in list)
pm2 delete www-3001       # remove from list
```

### Step 11 — Create public IP for Application Gateway

```bash
az network public-ip create \
  --resource-group $RESOURCE_GROUP \
  --name pip-agw-app \
  --location $LOCATION \
  --sku Standard \
  --allocation-method Static

AGW_IP=$(az network public-ip show \
  --resource-group $RESOURCE_GROUP \
  --name pip-agw-app \
  --query ipAddress -o tsv)

echo "AGW public IP: $AGW_IP"
```

### Step 12 — NSG for subnet-agw2 (required for AGW V2)

```bash
az network nsg create \
  --resource-group $RESOURCE_GROUP \
  --name nsg-agw-app \
  --location $LOCATION

# REQUIRED — AGW V2 management traffic (65200-65535)
# Without this rule, AGW fails to provision
az network nsg rule create \
  --resource-group $RESOURCE_GROUP \
  --nsg-name nsg-agw-app \
  --name allow-agw-infra \
  --priority 100 \
  --source-address-prefixes GatewayManager \
  --destination-address-prefixes '*' \
  --destination-port-ranges 65200-65535 \
  --protocol TCP \
  --access Allow \
  --direction Inbound

# Allow HTTP from internet to AGW frontend
az network nsg rule create \
  --resource-group $RESOURCE_GROUP \
  --nsg-name nsg-agw-app \
  --name allow-http \
  --priority 110 \
  --source-address-prefixes Internet \
  --destination-port-ranges 80 \
  --protocol TCP \
  --access Allow \
  --direction Inbound

az network vnet subnet update \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name subnet-agw2 \
  --network-security-group nsg-agw-app
```

### Step 13 — Create Application Gateway

```bash
# Get vm-private's private IP for the backend pool
PRIVATE_IP=$(az vm show \
  --resource-group $RESOURCE_GROUP \
  --name vm-private \
  --show-details --query privateIps -o tsv)

az network application-gateway create \
  --resource-group $RESOURCE_GROUP \
  --name agw-app \
  --location $LOCATION \
  --vnet-name $VNET_NAME \
  --subnet subnet-agw2 \
  --public-ip-address pip-agw-app \
  --sku Standard_v2 \
  --capacity 1 \
  --http-settings-port 3001 \
  --http-settings-protocol Http \
  --frontend-port 80 \
  --servers $PRIVATE_IP \
  --priority 100
```

> This takes **5–10 minutes** to provision.

**What this one command creates under the hood:**

| Component | What it does |
|-----------|-------------|
| Frontend IP | Binds to `pip-agw-app` (public IP) |
| Listener | Accepts HTTP on port 80 from internet |
| Backend pool | Contains `$PRIVATE_IP` (vm-private) |
| HTTP settings | Forwards traffic to port 3001 on backend |
| Routing rule | Listener → Backend pool |
| Health probe (default) | `GET /` to port 3001 every 30s |

### Step 14 — Add proper health probe pointing to /health

```bash
az network application-gateway probe create \
  --resource-group $RESOURCE_GROUP \
  --gateway-name agw-app \
  --name probe-nodejs \
  --protocol Http \
  --host-name-from-http-settings true \
  --path /health \
  --interval 30 \
  --timeout 30 \
  --threshold 3

az network application-gateway http-settings update \
  --resource-group $RESOURCE_GROUP \
  --gateway-name agw-app \
  --name appGatewayBackendHttpSettings \
  --probe probe-nodejs
```

> Every 30s AGW hits `GET /health` on vm-private. `200 OK` = healthy, stays in pool.
> 3 consecutive failures = removed from pool, no traffic sent until it recovers.

---

## Part 7 — Final Tests

### Test C — Hit the app through AGW from internet

```bash
# From your local machine (laptop)
curl -s http://$AGW_IP
# Expected: HTML page "Main Site"

curl -s http://$AGW_IP/health
# Expected: {"status":"healthy","app":"www","port":3001}
```

### Test D — Prove vm-private is still NOT directly reachable

```bash
# Try to reach vm-private directly from your laptop — should fail
curl --connect-timeout 5 http://$PRIVATE_IP:3001
# Expected: connection refused or timeout
# Reason: private IP is not routable from internet
#          even if it were, NSG blocks port 3001 from Internet source
```

### Test E — Check backend health from Azure side

```bash
az network application-gateway show-backend-health \
  --resource-group $RESOURCE_GROUP \
  --name agw-app \
  --query "backendAddressPools[0].backendHttpSettingsCollection[0].servers" \
  -o table
# Expected: address=10.10.2.x   health=Healthy
```

### Test F — Simulate failure (shows health probe auto-recovery)

```bash
# Inside vm-private: stop the app
pm2 stop www-3001

# From your laptop — wait ~90 seconds for probe to fail 3x, then:
curl -s http://$AGW_IP
# Expected: 502 Bad Gateway — AGW detected backend is down

# Inside vm-private: bring it back
pm2 start www-3001

# Wait ~30 seconds for probe to succeed, then:
curl -s http://$AGW_IP
# Expected: HTML page — AGW auto-recovered, no manual intervention needed
```

---

## Traffic flow — full picture

```
Your browser → http://$AGW_IP (port 80)
                    │
                    ▼
         Application Gateway (subnet-agw2: 10.10.3.x)
         - Terminates HTTP connection
         - Checks routing rule → forward to backend pool
         - Forwards to 10.10.2.x:3001 (vm-private private IP)
                    │
                    ▼
         vm-private (subnet-backend: 10.10.2.x)
         - Node.js receives request on port 3001
         - Source IP it sees: 10.10.3.x (AGW's private IP, not your laptop's)
         - NSG: 10.10.3.0/24 is allowed on port 3001 ✅
         - Returns HTML response
                    │
                    ▼
         AGW forwards response back to your browser ✅

Direct attempt: your laptop → http://10.10.2.x:3001
         - Private IP — not routable from internet ❌
         - NSG: Internet source blocked on port 3001 ❌
```

---

## Complete Summary

| | vm-public | vm-private |
|-|-----------|------------|
| Public IP | ✅ `pip-vm-public` | ❌ None |
| Subnet | `subnet-agw` (10.10.1.0/24) | `subnet-backend` (10.10.2.0/24) |
| AGW subnet | — | `subnet-agw2` (10.10.3.0/24) |
| Route table | None — Azure default active | `rt-private-demo` |
| SSH from internet | ✅ Directly | ❌ Jump host only |
| `ping 8.8.8.8` (initial) | ✅ Works | ❌ Blackholed |
| `ping 8.8.8.8` (after NAT GW) | ✅ Works | ✅ Works via NAT GW |
| App reachable from internet | — | ✅ Only via AGW on port 80 |
| App reachable directly from internet | — | ❌ NSG blocks it |

---

