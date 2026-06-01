# Phase 08 — PostgreSQL Private Link

> **Lab:** APIM 3 — Public APIM → Private AGW → AKS (httpbin)
> **Source:** [readme.md](../readme.md) → Step 8

---

## Overview

Add a private PostgreSQL Flexible Server as the database layer for the Orders API.

```
Full request path after this phase:

  Client → APIM (public) → AGW private (10.0.3.4) → ILB (10.0.1.50)
    → orders-service pod → pg-task10.postgres.database.azure.com
                               → Private DNS Zone → 10.0.4.x
                               → PostgreSQL Flexible Server (no public IP)
```

> PostgreSQL uses **VNet Integration** (subnet delegation), not a private endpoint.
> Critical rules: do NOT attach NSG, UDR, or private subnet flag to `snet-postgres`.

---

## 8.1 Create delegated subnet for PostgreSQL

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

> ⚠️ Do NOT attach NSG, UDR, or private subnet flag to `snet-postgres`. Any of these cause
> PostgreSQL provisioning to fail permanently.

---

## 8.2 Create PostgreSQL Flexible Server

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

---

## 8.3 Verify Private DNS Zone and VNet link

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

# If VNet link is missing:
az network private-dns link vnet create \
  --resource-group $RESOURCE_GROUP \
  --zone-name "${PG_NAME}.private.postgres.database.azure.com" \
  --name link-vnet-myapp \
  --virtual-network $VNET_NAME \
  --registration-enabled false
```

---

## 8.4 Test DNS resolution and create app database

```bash
kubectl run psql-client \
  --image=postgres:16 \
  --restart=Never \
  --rm -it \
  -- bash

# Inside pod — DNS check
nslookup pg-task10.postgres.database.azure.com
# MUST return 10.0.4.x (private IP)
# If returns public IP → Private DNS Zone not linked to vnet-myapp → fix link above

psql -h pg-task10.postgres.database.azure.com -U pgadmin -d postgres
# password: PgAdmin@Task10!

CREATE DATABASE ordersdb;
CREATE USER ordersuser WITH PASSWORD 'Orders@Task10!';
GRANT ALL PRIVILEGES ON DATABASE ordersdb TO ordersuser;
\q
exit
```

---

## 8.5 Store credentials as Kubernetes Secret

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

---

## 8.6 Verify no public access

```bash
# From your laptop (not from pod) — must fail
psql -h pg-task10.postgres.database.azure.com -U pgadmin -d postgres
# Expected: connection timeout ✅ (public access disabled)
```

---

## 8.7 Apply NetworkPolicy (restrict DB access to orders pods only)

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
# httpbin pods, monitoring sidecars — all blocked
```

---

## PostgreSQL vs Private Endpoint — key difference

| | PostgreSQL Flexible Server | ACR / Key Vault |
|---|---|---|
| Method | VNet Integration (subnet delegation) | Private Endpoint (NIC in subnet) |
| Subnet | Dedicated delegated — only PG allowed | Shared — multiple PEs can coexist |
| DNS zone | `pg-task10.private.postgres.database.azure.com` | `privatelink.azurecr.io` etc. |
| NSG/UDR | ❌ Cannot attach — breaks provisioning | ✅ Optional |

---

## Phase 08 complete? ⬜ nslookup returns private IP, K8s Secret created, NetworkPolicy applied.
