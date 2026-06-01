# Phase 09 — Workload Identity + Key Vault Secret from Pod

> **Lab:** APIM 3 — Public APIM → Private AGW → AKS (httpbin)
> **Source:** [readme.md](../readme.md) → Step 9

---

## Overview

K8s Secrets are base64-encoded, not encrypted at rest by default. Anyone with cluster access can read them.

Workload Identity solves this: the pod fetches the secret directly from Key Vault using a Managed Identity token — **no password ever touches the cluster**.

```
Without Workload Identity:
  Pod reads K8s Secret → gets PG password as env var
  Risk: visible to anyone with kubectl get secret

With Workload Identity (after this phase):
  Pod → OIDC token → Azure AD → Managed Identity token
  Pod → Key Vault API → fetches pg-password secret
  No password in K8s Secret, no password in pod spec

Token exchange flow:
  1. AKS OIDC issuer signs a K8s ServiceAccount token
  2. Pod SDK sends that token to Azure AD
  3. Azure AD validates issuer URL + subject (namespace/serviceaccount)
  4. Returns short-lived Azure access token for Managed Identity
  5. Pod uses that token to call Key Vault — auto-refreshed
```

---

## 9.1 Enable OIDC issuer + Workload Identity on AKS

```bash
az aks show \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_NAME \
  --query "oidcIssuerProfile" -o json
# If enabled: true → skip

az aks update \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_NAME \
  --enable-oidc-issuer \
  --enable-workload-identity
```

---

## 9.2 Create Key Vault and store secret

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

> **Key Vault stays public here** for simplicity.
> In production, add a private endpoint to `snet-aks` and disable public access.

---

## 9.3 Create Managed Identity

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

---

## 9.4 Assign Key Vault Secrets User role

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

---

## 9.5 Create federated credential

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

**Portal:**
```
Managed Identities → wi-apim3 → Settings → Federated credentials → + Add credential

  Scenario          → Kubernetes accessing Azure resources
  Cluster Issuer URL → paste OIDC URL from above
  Namespace          → orders
  Service account    → orders-sa
  Name               → apim3-federated-cred
  Audience           → api://AzureADTokenExchange

→ Add
```

> ⚠️ Namespace `orders` and service account `orders-sa` must **exactly** match what you
> create in Step 9.6. Mismatch → silent 401 from Key Vault.

---

## 9.6 Create Kubernetes ServiceAccount

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

---

## 9.7 Deploy pod and read Key Vault secret

**`kv-reader-pod.yaml`:**

```yaml
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
```

---

## How Workload Identity works internally

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
  → Auto-refreshed

What is NOT in your cluster:
  ❌ No client secrets
  ❌ No storage account keys
  ❌ No base64-encoded passwords in K8s Secrets
  ✅ Just a ServiceAccount + one label
```

---

## Phase 09 complete? ⬜ Pod reads KV secret without any credentials in its spec.
