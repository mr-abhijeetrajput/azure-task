# Phase 10 — Blob Storage Access from Pod (Workload Identity)

> **Lab:** APIM 3 — Public APIM → Private AGW → AKS (httpbin)
> **Source:** [readme.md](../readme.md) → Step 10

> **Prerequisite:** Phase 09 must be complete. Reuses `orders-sa` ServiceAccount and `wi-apim3` Managed Identity.

---

## Overview

The orders service generates PDF receipts and stores them in blob storage. The pod uses Workload Identity to write receipts — **no storage account keys** in the pod spec or K8s Secrets.

```
Orders pod → Workload Identity token → Azure AD
              → Storage Blob Data Contributor role on orders-receipts container
              → Upload/download blobs
              → No account keys anywhere
```

---

## 10.1 Create Storage Account and container

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

# Upload a test receipt file
echo '{"order_id": "ORD-001", "amount": 4999, "status": "paid"}' > receipt-001.json

az storage blob upload \
  --account-name $STORAGE_NAME \
  --container-name orders-receipts \
  --name receipt-001.json \
  --file receipt-001.json \
  --auth-mode login

echo "Test file uploaded ✅"
```

---

## 10.2 Assign blob role to Managed Identity

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

**Portal:**
```
Storage accounts → stapim3lab → Containers → orders-receipts
→ Access control (IAM) → + Add role assignment
   Role    → Storage Blob Data Contributor
   Members → Managed identity → wi-apim3
→ Review + assign

⚠️ Must use Storage Blob Data * roles (data plane)
   Assigning Contributor (management plane) does NOT grant blob read/write
```

---

## 10.3 Deploy pod and test blob read/write

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
  serviceAccountName: orders-sa   # same SA as Phase 09
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

# Download blob — Workload Identity token, no account key
kubectl exec -it blob-orders -n orders -- \
  az storage blob download \
  --account-name $STORAGE_NAME \
  --container-name orders-receipts \
  --name receipt-001.json \
  --file /tmp/receipt-001.json \
  --auth-mode login

kubectl exec -it blob-orders -n orders -- cat /tmp/receipt-001.json
# Expected: {"order_id": "ORD-001", "amount": 4999, "status": "paid"} ✅

# Upload new blob from pod
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

---

## 10.4 Verify from laptop (via VPN)

```bash
az storage blob list \
  --account-name $STORAGE_NAME \
  --container-name orders-receipts \
  --auth-mode login \
  --query "[].name" -o tsv
# Expected: receipt-001.json, receipt-002.json ✅
```

---

## Production pattern — Azure SDK in app code

```python
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient
from azure.keyvault.secrets import SecretClient

credential = DefaultAzureCredential()  # picks up Workload Identity env vars in pod

# Read DB password from Key Vault
kv_client = SecretClient(
    vault_url="https://kv-apim3-lab.vault.azure.net",
    credential=credential
)
pg_password = kv_client.get_secret("pg-orders-password").value

# Upload receipt to blob
blob_client = BlobServiceClient(
    account_url="https://stapim3lab.blob.core.windows.net",
    credential=credential
)
container = blob_client.get_container_client("orders-receipts")
container.upload_blob(name=f"receipt-{order_id}.json", data=receipt_json)
```

---

## Phase 10 complete? ⬜ Pod downloads and uploads blobs using Workload Identity (no account keys).
