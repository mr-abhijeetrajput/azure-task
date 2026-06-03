# Phase 04 — AKS: httpbin ILB + Entra ID RBAC

> **Lab:** APIM 3 — Public APIM → Private AGW → AKS (httpbin)

---

## Overview

Three things happen in this phase:
1. Verify AKS private cluster is running (created in Phase 00)
2. Deploy httpbin with an Internal Load Balancer at `10.0.1.50`
3. Add Entra ID user/group access control on the AKS cluster (kubectl RBAC)

> ⚠️ **Phase 03 (VPN) must be complete and connected before running ANY kubectl command in this phase.**
> The AKS API server is private — there is no fallback public endpoint.

### Private cluster — how kubectl access works

```
aks-myapp.hcp.southindia.azmk8s.io → 10.0.1.x (private endpoint in snet-aks)
kubectl from laptop: ❌ (no VPN)  ✅ (VPN connected)
AKS node → API server: ✅ always (same VNet)
APIM/AGW/pods → API server: not needed (no change to data plane)
```

The **data plane is unaffected** — APIM → AGW → ILB → pods works identically.
Only the control plane (kubectl, `az aks get-credentials`, CI/CD pipelines) requires VPN.

### Two Entra ID layers — why both matter

```
Layer 1 — API-level auth (Phase 07):
  Client → APIM → validate-jwt checks Entra token for aud=api://orders

Layer 2 — Cluster-level auth (here):
  Engineer → kubectl → Entra ID token → AKS RBAC role check

APIM JWT   = who can call the Orders API
AKS RBAC   = who can run kubectl on the cluster
```

An attacker with a stolen JWT can call the API but still cannot access the cluster.

---

## 4.1 Verify AKS private cluster

> AKS was created as a private cluster in Phase 00. Verify it is running before proceeding.

```bash

AKS_NAME="aks-myapp"

az aks show \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_NAME \
  --query "{PrivateCluster:apiServerAccessProfile.enablePrivateCluster, PrivateFQDN:privateFqdn, State:provisioningState}" \
  -o table
# PrivateCluster : true  ✅
# PrivateFQDN    : aks-myapp.hcp.southindia.azmk8s.io
# State          : Succeeded  ✅
```

> **What Azure created automatically in Phase 00:**
> - A private DNS zone: `privatelink.southindia.azmk8s.io`
> - A VNet link from that zone to `vnet-myapp`
> - A private endpoint NIC in `snet-aks` with the API server IP
>
> You can verify: `az network private-endpoint list -g MC_rg-myapp_aks-myapp_southindia -o table`

---

## 4.2 Get AKS credentials (VPN must be connected)

> ⚠️ `az aks get-credentials` itself works without VPN (it just downloads the kubeconfig file).
> But any subsequent `kubectl` command will fail until the API server FQDN resolves to a
> private IP via Azure DNS through the tunnel.

```bash
# Download kubeconfig (works without VPN)
az aks get-credentials \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_NAME \
  --overwrite-existing

# This only works WITH VPN connected and Azure DNS resolving correctly:
kubectl get nodes
# Expected: node listed ✅
# Hangs or fails → check VPN DNS (phase-03 step 3.7 troubleshooting)
```

---

## 4.3 Deploy httpbin with Internal Load Balancer

> If `orders-svc` with EXTERNAL-IP `10.0.1.50` already exists from Phase 00, skip to 4.4.

```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: orders
  template:
    metadata:
      labels:
        app: orders
    spec:
      containers:
      - name: orders
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
    app: orders
  ports:
  - port: 80
    targetPort: 80
EOF

# Wait for ILB IP to be assigned (1–2 min)
kubectl get svc orders-svc -w
# EXTERNAL-IP must show 10.0.1.50 ✅
```

---

## 4.4 Get admin (bootstrap) kubeconfig

> Entra ID was enabled at cluster creation in Phase 00 (`--enable-aad --enable-azure-rbac`).
> Use `--admin` here to apply RBAC bindings without an Entra popup.

```bash
az aks get-credentials \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_NAME \
  --admin \
  --overwrite-existing

kubectl get nodes   # ✅ certificate auth, no Entra popup
```

---

## 4.5 Create Entra ID test users and group

```bash

az account tenant list --query "[].{TenantId:id, Domain:defaultDomainName}" -o table

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

# Collect Object IDs — MUST use OIDs in RoleBinding YAML, not email
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

---

## 4.6 Create orders namespace + apply K8s RBAC bindings

```bash
kubectl create namespace orders
```

Create `rbac-orders.yaml` — paste the four OIDs collected above:

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
> K8s matches on the `oid` claim in the Entra token.

```bash
kubectl apply -f rbac-orders.yaml

kubectl get clusterrolebindings | grep crb-
kubectl get rolebindings -n orders
```

---

## 4.7 Switch to Entra ID (non-admin) credentials

> ⚠️ **VPN must be connected** for every `kubectl` command below.
> The API server is private — there is no fallback.

```bash
sudo az aks install-cli   # installs kubelogin

az aks get-credentials \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_NAME \
  --overwrite-existing

kubectl get nodes
# → browser popup → login with your Entra account
# → nodes appear ✅ (requires VPN + Azure DNS resolving private FQDN)
```

---

## 4.8 Test access as each identity

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

---

## 4.9 Break-glass verification

```bash
az aks get-credentials \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_NAME \
  --admin

kubectl get nodes   # ✅ certificate auth, no Entra popup
# ⚠️ Audit-logged — use for emergencies only
# ⚠️ VPN still required — private cluster has no public API server even for --admin

# Return to Entra credentials
az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_NAME --overwrite-existing
```

---

## Phase 04 complete? ⬜ AKS private cluster verified, httpbin ILB at 10.0.1.50, RBAC bindings applied, all identity tests pass (with VPN connected).
