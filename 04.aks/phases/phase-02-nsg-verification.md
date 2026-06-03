# Phase 02 — NSG Verification (nsg-agw & nsg-apim)

> **Lab:** APIM 3 — Public APIM → Private AGW → AKS (httpbin)
> **Source:** [readme.md](../readme.md) → Step 0.1 & 0.2

---

## Overview

Two NSGs must have the correct rules before any other resource is deployed:
- `nsg-agw` — protects the AGW subnet; includes the **mandatory** AGW infra rule (required for both Standard_v2 and WAF_v2)
- `nsg-apim` — protects the APIM subnet; APIM 3 adds an internet-facing inbound rule

---

## 2.1 Verify nsg-agw rules

```bash
az network nsg show \
  -g $RESOURCE_GROUP \
  -n nsg-agw \
  --query "securityRules[].{Name:name, Priority:priority, Access:access}" \
  -o table
# Must include: allow-apim-to-agw (100), allow-agw-infra (105),
#               Azure-health-probe (115), allow-vnet (120)
```

### nsg-agw required rules

| Name | Priority | Source | Port | Action | Purpose |
|---|---|---|---|---|---|
| `allow-apim-to-agw` | 100 | `10.0.2.0/24` | 80 | Allow | APIM subnet → AGW |
| `allow-agw-infra` | 105 | `GatewayManager` | 65200-65535 | Allow | AGW control plane (mandatory for Standard_v2 and WAF_v2) |
| `Azure-health-probe` | 115 | `AzureLoadBalancer` | 6390 | Allow | AGW health |
| `allow-vnet` | 120 | `VirtualNetwork` | * | Allow | Intra-VNet |

> ⚠️ **`allow-agw-infra` is mandatory regardless of SKU.**
> Azure's backend (`GatewayManager`) needs TCP 65200-65535 to reach the AGW instance for
> health checks, config pushes, and scaling signals. Both Standard_v2 and WAF_v2 require it.
> Azure Portal blocks AGW creation if this rule is missing.

### Recreate missing nsg-agw rules

```bash
# allow-apim-to-agw
az network nsg rule create \
  --resource-group $RESOURCE_GROUP --nsg-name nsg-agw \
  --name allow-apim-to-agw --priority 100 --protocol Tcp --access Allow \
  --direction Inbound \
  --source-address-prefixes 10.0.2.0/24 \
  --destination-port-ranges 80

# allow-agw-infra — MANDATORY for Standard_v2 and WAF_v2, Azure control plane
az network nsg rule create \
  --resource-group $RESOURCE_GROUP --nsg-name nsg-agw \
  --name allow-agw-infra --priority 105 --protocol Tcp --access Allow \
  --direction Inbound \
  --source-address-prefixes GatewayManager \
  --destination-address-prefixes '*' \
  --destination-port-ranges 65200-65535

# Azure-health-probe
az network nsg rule create \
  --resource-group $RESOURCE_GROUP --nsg-name nsg-agw \
  --name Azure-health-probe --priority 115 --protocol "*" --access Allow \
  --direction Inbound \
  --source-address-prefixes AzureLoadBalancer \
  --destination-port-ranges 6390

# allow-vnet
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

---

## 2.2 Verify nsg-apim rules

```bash
az network nsg show \
  -g $RESOURCE_GROUP \
  -n nsg-apim \
  --query "securityRules[].{Name:name, Priority:priority, Direction:direction}" \
  -o table
```

### APIM 3-specific rules to add (if missing)

```bash
# Inbound: public clients → APIM gateway (APIM 3 — internet hits APIM first)
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
> Storage/Sql/KeyVault rules from `common-resources.md`. Do NOT delete them.

---

## Phase 02 complete? ⬜ Both NSGs have all required rules.
