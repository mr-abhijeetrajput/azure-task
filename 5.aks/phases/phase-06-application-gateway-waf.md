# Phase 06 — Application Gateway (Standard_v2, Private Frontend)

> **Lab:** APIM 3 — Public APIM → Private AGW → AKS (httpbin)
> **Source:** [readme.md](../readme.md) → Step 4

> Can be started while APIM is provisioning (Phase 05).

---

## Overview

Deploy AGW with:
- **Standard_v2** tier — routing hop between APIM and AKS ILB (no WAF needed; APIM policies handle API security)
- **Private frontend only** — `10.0.3.4` (first usable in `snet-agw`)
- **Dummy public IP** — Standard_v2 requires one, but the NSG blocks all internet inbound
- **Backend pool → ILB `10.0.1.50`** (httpbin)

### Why Standard_v2 (not WAF_v2)

APIM already handles API-level security — JWT validation, rate limiting, header stripping.
AGW's job here is purely routing: receive from APIM on `10.0.3.4`, forward to ILB `10.0.1.50`.
Standard_v2 does this with no OWASP overhead. WAF_v2 adds cost and complexity for a hop
that has no direct internet exposure. See the optional WAF_v2 section at the bottom of this
phase if you want OWASP inspection anyway.

### Why AGIC is NOT used here

| Pattern | When to use |
|---|---|
| **AGIC** | AKS-native routing, no API management layer, dev-controlled ingress |
| **APIM + static AGW (this lab)** | Enterprise API gateway with policies; AGW is a routing hop, not the entry point |

APIM is the public entry point and owns routing decisions (JWT, rate limit, path rewriting).
AGW forwards from APIM to ILB — it does not make routing decisions.

---

## 6.1 Create dummy public IP for AGW

> Standard_v2 / WAF_v2 SKUs **require** a public IP — Azure blocks creation without one.
> The NSG on `snet-agw` blocks all internet inbound, so this IP is effectively unused.

```bash
az network public-ip create \
  --name $PIP_AGW \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Standard \
  --allocation-method Static
# No --dns-name needed — this IP will never be used for DNS
```

---

## 6.2 Create AGW (Standard_v2)

**Portal:** `Application Gateway` → `Create`

| Tab | Field | Value |
|---|---|---|
| Basics | Name | `agw-myapp-priv` |
| Basics | Tier | **`Standard V2`** |
| Networking | VNet / Subnet | `vnet-myapp` / `snet-agw` |
| Frontends | Frontend IP type | **`Both`** ← Standard_v2 requires a public IP to exist |
| Frontends | Public IP | `pip-agw-myapp-priv` (dummy) |
| Frontends | Private IP | `10.0.3.4` (static) |
| Backends | Pool name | `pool-aks` |
| Backends | Target type | **`IP address or FQDN`** ← NOT VMSS (see warning below) |
| Backends | Target | `10.0.1.50` |
| Configuration | Rule name | `rule-apim-to-aks` |
| Configuration | Rule priority | `100` |
| Configuration | Listener | `listener-http` · HTTP · port 80 · Frontend: **Private** |
| Configuration | Backend settings | `settings-aks` · HTTP · port 80 |
| Configuration | Routing rule type | `Basic` |

> ⚠️ **VMSS backend causes 502 — always use ILB IP instead.**
> When you select `VMSS` as backend type, Azure registers the VMSS node IP (e.g. `10.0.1.4`)
> directly. The AGW health probe hits the node at port 80 — but nothing listens there; httpbin
> only listens via the ILB. This causes `Unhealthy` backend and `502 Bad Gateway`.
>
> Fix if already created with VMSS:
> ```bash
> az network application-gateway address-pool update \
>   --resource-group rg-myapp \
>   --gateway-name agw-myapp-priv \
>   --name pool-aks \
>   --servers 10.0.1.50
> ```

**CLI:**
```bash
az network application-gateway create \
  --resource-group $RESOURCE_GROUP \
  --name $AGW_NAME \
  --location $LOCATION \
  --sku Standard_v2 \
  --capacity 2 \
  --vnet-name $VNET_NAME \
  --subnet $AGW_SUBNET \
  --public-ip-address $PIP_AGW \
  --private-ip-address 10.0.3.4 \
  --servers 10.0.1.50 \
  --frontend-port 80 \
  --http-settings-port 80 \
  --http-settings-protocol Http \
  --routing-rule-type Basic
```

---

## 6.3 Add health probe

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

---

## 6.4 Verify backend health

```bash
az network application-gateway show-backend-health \
  --resource-group $RESOURCE_GROUP \
  --name $AGW_NAME \
  --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].{IP:address, Health:health}" \
  -o table
# Expected: 10.0.1.50  Healthy
```

---

## 6.5 Verify AGW reachable via VPN

```bash
# Must be on VPN (Phase 03)
curl http://10.0.3.4/get
# Expected: httpbin JSON ✅  confirms AGW → ILB → pod chain works
```

---

## Phase 06 complete? ⬜ AGW backend `10.0.1.50` is Healthy, `curl 10.0.3.4/get` returns httpbin JSON.

---

---

## Optional: Upgrade to WAF_v2

> Follow this section only if you want OWASP rule-based traffic inspection on the AGW hop.
> Skip entirely if Standard_v2 is sufficient (default for this lab).

### Why you might want WAF_v2

- OWASP Core Rule Set (SQLi, XSS, LFI, RFI, etc.) applied at the AGW layer
- WAF diagnostic logs for traffic inspection independent of APIM logs
- Requirement to demonstrate WAF_v2 as part of the lab coverage

### What changes vs Standard_v2

| | Standard_v2 (default) | WAF_v2 (optional) |
|---|---|---|
| SKU flag | `--sku Standard_v2` | `--sku WAF_v2` |
| WAF policy | Not needed | Required — create before AGW |
| Portal tier | `Standard V2` | `WAF V2` |
| Portal WAF tab | Not shown | Set policy + mode |
| Phase 01 variable | `WAF_POLICY` not needed | Add `WAF_POLICY="apim3-waf"` |

### Step 1 — Add WAF_POLICY variable (Phase 01)

Add this to your shell variables block:

```bash
WAF_POLICY="apim3-waf"
```

### Step 2 — Create WAF policy before AGW

```bash
az network application-gateway waf-policy create \
  --resource-group $RESOURCE_GROUP \
  --name $WAF_POLICY \
  --location $LOCATION
```

### Step 3 — Create AGW with WAF_v2 instead

Replace the Standard_v2 CLI command in 6.2 with:

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

In the Portal, select `WAF V2` as tier and on the WAF tab select policy `apim3-waf` with mode **Detection**.

> **Detection vs Prevention:** Start in Detection — WAF logs rule matches but does not block.
> Switch to Prevention only after reviewing logs and tuning exclusions to avoid false-positive 403s.

### Step 4 — Additional verify steps (WAF_v2 only)

```bash
# WAF policy attached
az network application-gateway show \
  --resource-group $RESOURCE_GROUP \
  --name $AGW_NAME \
  --query "firewallPolicy.id" -o tsv
# Expected: .../apim3-waf

# WAF in Detection mode
az network application-gateway waf-policy show \
  --resource-group $RESOURCE_GROUP \
  --name $WAF_POLICY \
  --query "policySettings.mode" -o tsv
# Expected: Detection
```
