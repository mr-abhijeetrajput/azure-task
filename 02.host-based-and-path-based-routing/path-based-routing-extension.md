# Path-Based Routing Extension — shop.abhijeetrajput.life

> **Prerequisite:** `path-based.md` lab must be fully complete (all 10 phases including HTTPS).
> This adds path-based routing on top of the existing host-based setup.
> Everything else stays as-is. Only shop gets path-based routing.

---

## What We're Adding

```
BEFORE (host-based only):
shop.abhijeetrajput.life/*   →  pool-shop  (VM2:3003)

AFTER (host-based + path-based):
shop.abhijeetrajput.life/        →  pool-shop  (VM2:3003)  ← default, unchanged
shop.abhijeetrajput.life/cart    →  pool-cart  (VM2:3005)  ← new path rule
shop.abhijeetrajput.life/cart/*  →  pool-cart  (VM2:3005)  ← new path rule
```

This is the standard microservices pattern — one domain, multiple backend services
split by URL path, all sitting behind a single Application Gateway listener.

---

## Why only rule-shop-https is PathBasedRouting — not rule-shop

```
rule-shop        Basic            listener-shop (port 80)   → redirect to HTTPS only
rule-shop-https  PathBasedRouting shop-www-https (port 443) → forwards to backend pools
```

`rule-shop` (HTTP, port 80) stays Basic because its only job is redirecting to HTTPS — it never touches a backend pool, so path awareness is pointless. Path-based routing only matters on `rule-shop-https` (port 443) which is the rule that actually routes traffic to backends.

---

## Step 1 — Create Cart App on VM2 (port 3005)

SSH into VM2 via Serial Console:
**Portal → vm2 → Help → Serial Console**

```bash
mkdir -p ~/apps/cart && cat << 'EOF' > ~/apps/cart/app.js
const http = require('http');
const port = 3005;

http.createServer((req, res) => {
  if (req.url === '/health' || req.url === '/cart/health') {
    res.writeHead(200, {'Content-Type': 'application/json'});
    res.end(JSON.stringify({ status: 'healthy', app: 'cart', port: 3005 }));
    return;
  }
  res.writeHead(200, {'Content-Type': 'text/html'});
  res.end(`<html><body style="font-family:sans-serif;padding:40px;background:#fce4ec">
    <h1>🛒 Cart Service</h1>
    <h2>shop.abhijeetrajput.life/cart</h2>
    <p>VM2 | Port 3005</p>
    <p>Path hit: <b>${req.url}</b></p>
  </body></html>`);
}).listen(port, () => console.log('cart on :' + port));
EOF

pm2 start ~/apps/cart/app.js --name cart-3005
pm2 save

# Verify locally
curl http://localhost:3005
curl http://localhost:3005/health
```

---

## Step 2 — Allow Port 3005 in NSG

```bash
RESOURCE_GROUP="rg-task01"

az network nsg rule update \
  --resource-group $RESOURCE_GROUP \
  --nsg-name nsg-backend \
  --name allow-apps-from-agw \
  --destination-port-ranges 3001 3002 3003 3004 3005
```

---

## Step 3 — Create Backend Pool for Cart

```bash
VM2_IP=$(az vm list-ip-addresses \
  --resource-group $RESOURCE_GROUP \
  --name vm2 \
  --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv)

echo "VM2 IP: $VM2_IP"

az network application-gateway address-pool create \
  --gateway-name agw-abhijeet \
  --resource-group $RESOURCE_GROUP \
  --name pool-cart \
  --servers $VM2_IP
```

---

## Step 4 — Create Backend HTTP Setting for Cart

```bash
az network application-gateway http-settings create \
  --gateway-name agw-abhijeet \
  --resource-group $RESOURCE_GROUP \
  --name setting-cart \
  --port 3005 \
  --protocol Http \
  --timeout 30
```

---

## Step 5 — Create Health Probe for Cart *(Optional — skip for now)*

> AGW will use the default probe (hits `/` every 30s) if this step is skipped.
> Come back to this later using the pattern from Phase 8 of `path-based.md`.

```bash
az network application-gateway probe create \
  --resource-group $RESOURCE_GROUP \
  --gateway-name agw-abhijeet \
  --name probe-cart \
  --protocol Http \
  --path /health \
  --interval 15 \
  --timeout 10 \
  --threshold 3 \
  --port 3005 \
  --host $VM2_IP \
  --match-status-codes 200-399

# Attach probe to setting-cart
PROBE_ID=$(az network application-gateway show \
  --resource-group $RESOURCE_GROUP \
  --name agw-abhijeet \
  --query "probes[?name=='probe-cart'].id" -o tsv)

az network application-gateway http-settings update \
  --resource-group $RESOURCE_GROUP \
  --gateway-name agw-abhijeet \
  --name setting-cart \
  --probe $PROBE_ID
```

---

## Step 6 — Create URL Path Map

> Creates `pathmap-shop` with path routing logic defined. Not attached to any rule yet — no traffic affected. **Not visible in Portal** until Step 7 attaches it to a rule.

This is the core of path-based routing. The path map defines:
- `/cart/*` → pool-cart (port 3005)
- everything else → pool-shop (port 3003) — the default

```bash
az network application-gateway url-path-map create \
  --gateway-name agw-abhijeet \
  --resource-group $RESOURCE_GROUP \
  --name pathmap-shop \
  --paths /cart/* \
  --address-pool pool-cart \
  --http-settings setting-cart \
  --default-address-pool pool-shop \
  --default-http-settings setting-shop
```

Verify path map was created:

```bash
az network application-gateway url-path-map list \
  --gateway-name agw-abhijeet \
  --resource-group $RESOURCE_GROUP \
  --query "[].{Name:name, Rules:pathRules[].{Path:paths, Pool:backendAddressPool.id}}" \
  --output table
```

---

## Step 7 — Replace shop HTTPS rule with PathBasedRouting rule

The existing `rule-shop-https` is a Basic rule (no path awareness). We need to delete it
and recreate it as a `PathBasedRouting` rule pointing to the path map.

```bash
# Delete existing basic rule
az network application-gateway rule delete \
  --gateway-name agw-abhijeet \
  --resource-group $RESOURCE_GROUP \
  --name rule-shop-https

# Recreate as PathBasedRouting
# --address-pool and --http-settings are required when multiple pools exist
az network application-gateway rule create \
  --gateway-name agw-abhijeet \
  --resource-group $RESOURCE_GROUP \
  --name rule-shop-https \
  --priority 310 \
  --http-listener shop-www-https \
  --rule-type PathBasedRouting \
  --url-path-map pathmap-shop \
  --address-pool pool-shop \
  --http-settings setting-shop
```

> Note: listener name is `shop-www-https` (not `listener-shop-https`) — verified during the original lab.

---

## Step 8 — Add Exact /cart Path Rule

> `/cart/*` only matches `/cart/something` — it does NOT match `/cart` alone.
> This step adds an exact match for `/cart` so both work correctly.

```bash
az network application-gateway url-path-map rule create \
  --gateway-name agw-abhijeet \
  --resource-group $RESOURCE_GROUP \
  --path-map-name pathmap-shop \
  --name cart-exact \
  --paths /cart \
  --address-pool pool-cart \
  --http-settings setting-cart
```

---

## Step 9 — Verify

### Check backend health

```bash
az network application-gateway show-backend-health \
  --resource-group $RESOURCE_GROUP \
  --name agw-abhijeet \
  --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].{Address:address, Health:health}" \
  --output table
```

### curl tests

```bash
# Default path → shop (port 3003)
curl https://shop.abhijeetrajput.life
# Expected: 🛒 Shop | VM2 | Port 3003

# /cart exact → cart service (port 3005)
curl https://shop.abhijeetrajput.life/cart
# Expected: 🛒 Cart Service | VM2 | Port 3005

# /cart/anything → cart service (port 3005)
curl https://shop.abhijeetrajput.life/cart/checkout
# Expected: 🛒 Cart Service | path hit: /cart/checkout
```

---

## Architecture After This Extension

```
Internet
    │
    ▼
shop.abhijeetrajput.life  →  AGW Public IP
    │
    ▼
┌─────────────────────────────────────────────────────────┐
│                  Application Gateway                     │
│                                                          │
│  rule-shop        [Basic]           port 80              │
│      └── redirect only → https://shop.abhijeetrajput.life│
│                                                          │
│  rule-shop-https  [PathBasedRouting] port 443            │
│      │                                                   │
│      ├── /cart    ──────────────────► pool-cart (3005)  │
│      ├── /cart/*  ──────────────────► pool-cart (3005)  │
│      │                                                   │
│      └── /* (default) ──────────────► pool-shop (3003)  │
└─────────────────────────────────────────────────────────┘
                                │             │
                                ▼             ▼
                           VM2:3005       VM2:3003
                         Cart Service   Shop Frontend
```

---

## Key Concepts Covered

| Concept | What it means |
|---|---|
| **Host-based routing** | Route by domain name (listener hostname) |
| **Path-based routing** | Route by URL path within same domain |
| **URL Path Map** | AGW resource that maps paths → backend pools |
| **PathBasedRouting rule** | Rule type that attaches a URL path map |
| **Default backend** | Where traffic goes if no path rule matches |
| `/cart/*` vs `/cart` | Wildcard does NOT match exact path — both rules needed |
| **Why rule-shop stays Basic** | HTTP redirect rule never touches a backend — path awareness not needed |
| **Mixing both types** | www/blog = host-based, shop = path-based — both work together |

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `/cart` hitting shop (port 3003) | Add exact `/cart` rule via Step 8 — `/cart/*` alone won't match `/cart` |
| `/cart/checkout` hitting shop | Check path map rule has `/cart/*` — verify with `url-path-map list` |
| 502 on `/cart` | Check NSG allows port 3005, check pm2 status on VM2 |
| `rule-shop-https` create fails | Verify listener name with `az network application-gateway http-listener list` |
| "Multiple backend address pools found" | Add `--address-pool pool-shop --http-settings setting-shop` to the rule create command |
| pool-cart shows Unhealthy | Default probe hitting `/` — add custom probe from `path-based.md` Phase 8 pattern |
