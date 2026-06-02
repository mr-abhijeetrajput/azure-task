# Cross-RG Resource Access — RBAC + Managed Identity
### VM in RG-A reads/writes Storage Account in RG-B using zero credentials in code

> **What you will build:**
> `rg-vm` holds a Linux VM. `rg-storage` holds a Storage Account.
> The VM gets a system-assigned Managed Identity. An RBAC role is assigned on the
> Storage Account scoped to that identity. The VM uploads and downloads blobs
> using `az login --identity` — no keys, no secrets anywhere.

---

## Architecture

```
Azure Subscription
│
├── rg-vm  (Resource Group A)
│   └── vm-cross-rg
│       ├── NIC  → subnet-backend (10.10.2.0/24) inside vnet-task07
│       └── System-assigned Managed Identity
│           └── Object ID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
│
└── rg-storage  (Resource Group B)
    └── Storage Account: storetask07<random>
        ├── Container: uploads
        └── IAM → Role Assignment
            ├── Role  : Storage Blob Data Contributor
            ├── Scope : /subscriptions/.../rg-storage/providers/.../storetask07
            └── Principal: vm-cross-rg Managed Identity (Object ID above)

Flow:
  vm-cross-rg
      │  1. az login --identity  →  Azure AD issues OAuth token for the MI
      │  2. az storage blob upload  (token sent in Authorization header)
      ▼
  Azure AD validates token → checks RBAC → role exists on storage account → ALLOW
      │
      ▼
  Storage Account (rg-storage) — data plane accepts the request ✅
```

---

## Why Managed Identity + RBAC (not storage keys)

| Approach | Key stored in | Risk |
|---|---|---|
| Storage access key | VM env var / code / Key Vault | Key leaked = full account access forever |
| SAS token | URL / code | Expires but hard to revoke early |
| **Managed Identity** | **Nowhere — Azure manages it** | No secret to leak |

The MI is issued a short-lived token by Azure AD automatically. No rotation needed. Revoke
access instantly by removing the role assignment.

---

## PRE-STEP — Environment Variables

```bash
LOCATION="southindia"
RG_VM="rg-vm"
RG_STORAGE="rg-storage"
VM_NAME="vm-cross-rg"
VNET_NAME="vnet-task07"
STORAGE_ACCOUNT="storetask07$RANDOM"   # save the exact name after creation
```

---

## Step 0 — Create Both Resource Groups

```bash
az group create --name $RG_VM      --location $LOCATION
az group create --name $RG_STORAGE --location $LOCATION
```

---

## Step 1 — Create Storage Account in rg-storage

```bash
az storage account create \
  --resource-group $RG_STORAGE \
  --name $STORAGE_ACCOUNT \
  --location $LOCATION \
  --sku Standard_LRS \
  --kind StorageV2 \
  --allow-blob-public-access false \
  --min-tls-version TLS1_2

echo "Storage account: $STORAGE_ACCOUNT"
```

Create a container to upload blobs into:

```bash
az storage container create \
  --account-name $STORAGE_ACCOUNT \
  --name uploads \
  --auth-mode login
```

> If this fails with AuthorizationError, your own account needs the same
> `Storage Blob Data Contributor` role on the storage account — add it in Step 4.

---

## Step 2 — Create VNet + Subnet + VM in rg-vm

```bash
# VNet and subnet
az network vnet create \
  --resource-group $RG_VM \
  --name $VNET_NAME \
  --location $LOCATION \
  --address-prefixes 10.10.0.0/16

az network vnet subnet create \
  --resource-group $RG_VM \
  --vnet-name $VNET_NAME \
  --name subnet-backend \
  --address-prefixes 10.10.2.0/24

# NSG — allow SSH for this lab
az network nsg create \
  --resource-group $RG_VM \
  --name nsg-vm \
  --location $LOCATION

az network nsg rule create \
  --resource-group $RG_VM \
  --nsg-name nsg-vm \
  --name allow-ssh \
  --priority 100 \
  --source-address-prefixes Internet \
  --destination-port-ranges 22 \
  --protocol TCP \
  --access Allow \
  --direction Inbound

# VM with public IP (for SSH access in this lab)
az vm create \
  --resource-group $RG_VM \
  --name $VM_NAME \
  --location $LOCATION \
  --image Ubuntu2204 \
  --size Standard_B2ts_v2 \
  --vnet-name $VNET_NAME \
  --subnet subnet-backend \
  --nsg nsg-vm \
  --public-ip-address pip-vm-cross-rg \
  --public-ip-sku Standard \
  --admin-username azureuser \
  --generate-ssh-keys

VM_PUBLIC_IP=$(az vm show \
  --resource-group $RG_VM \
  --name $VM_NAME \
  --show-details --query publicIps -o tsv)

echo "VM public IP: $VM_PUBLIC_IP"
```

---

## Step 3 — Enable System-Assigned Managed Identity on VM

```bash
az vm identity assign \
  --resource-group $RG_VM \
  --name $VM_NAME

# Get the identity's Object (Principal) ID
MI_PRINCIPAL_ID=$(az vm identity show \
  --resource-group $RG_VM \
  --name $VM_NAME \
  --query principalId -o tsv)

echo "Managed Identity Principal ID: $MI_PRINCIPAL_ID"
```

> What just happened: Azure registered a service principal in Azure AD for this VM.
> The VM can now request tokens for any Azure resource — but it has no permissions yet.

---

## Step 4 — Assign RBAC Role on the Storage Account

The role assignment is scoped to the storage account in `rg-storage`.
The principal is the VM's managed identity (in `rg-vm`).
**Resource groups don't matter for RBAC — scope is set on the resource, not the RG.**

```bash
# Get the storage account's full resource ID
STORAGE_ID=$(az storage account show \
  --resource-group $RG_STORAGE \
  --name $STORAGE_ACCOUNT \
  --query id -o tsv)

echo "Storage resource ID: $STORAGE_ID"

# Assign role
az role assignment create \
  --assignee $MI_PRINCIPAL_ID \
  --role "Storage Blob Data Contributor" \
  --scope $STORAGE_ID
```

Verify the assignment was created:

```bash
az role assignment list \
  --scope $STORAGE_ID \
  --assignee $MI_PRINCIPAL_ID \
  --query "[].{Role:roleDefinitionName, Principal:principalId, Scope:scope}" \
  -o table

# Expected:
# Role                          Principal                             Scope
# ────────────────────────────  ────────────────────────────────────  ─────────────────────────
# Storage Blob Data Contributor xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx  /subscriptions/.../storetask07...
```

> RBAC propagation takes up to 2 minutes. If access is denied immediately after
> assignment, wait and retry.

---

## Step 5 — Test Cross-RG Access from Inside the VM

SSH into the VM:

```bash
ssh azureuser@$VM_PUBLIC_IP
```

Inside the VM, run:

```bash
# Install Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Authenticate as the VM's managed identity (no password, no keys)
az login --identity

# Check what identity we are logged in as
az account show --query user -o json
# Expected:
# {
#   "assignedIdentityInfo": "MSIResource-/subscriptions/.../vm-cross-rg",
#   "name": "...",
#   "type": "servicePrincipal"
# }

# Set storage account name (replace with your actual name)
STORAGE_ACCOUNT="storetask07<your-random-suffix>"

# Upload a test file (writing TO rg-storage FROM rg-vm)
echo "Cross-RG write from vm-cross-rg (rg-vm) to storage (rg-storage)" > /tmp/cross-rg-test.txt

az storage blob upload \
  --account-name $STORAGE_ACCOUNT \
  --container-name uploads \
  --name cross-rg-test.txt \
  --file /tmp/cross-rg-test.txt \
  --auth-mode login

# List blobs to confirm upload worked
az storage blob list \
  --account-name $STORAGE_ACCOUNT \
  --container-name uploads \
  --auth-mode login \
  --query "[].{Name:name, Size:properties.contentLength}" \
  -o table

# Download back and verify content
az storage blob download \
  --account-name $STORAGE_ACCOUNT \
  --container-name uploads \
  --name cross-rg-test.txt \
  --file /tmp/downloaded.txt \
  --auth-mode login

cat /tmp/downloaded.txt
# Expected: Cross-RG write from vm-cross-rg (rg-vm) to storage (rg-storage)
```

---

## Step 6 — Prove It's the Identity, Not Keys

```bash
# Still inside the VM — try accessing WITHOUT managed identity (no key, no token)
az logout
az storage blob list \
  --account-name $STORAGE_ACCOUNT \
  --container-name uploads \
  --auth-mode login

# Expected error: AADSTS70043 or "Please run az login to access your accounts"
# Proves the access came from the identity, not any cached key or anonymous access
```

---

## Step 7 — Use with Python (SDK — production pattern)

For real applications you use the Azure SDK, not CLI. The SDK reads the managed
identity automatically via `DefaultAzureCredential`:

```bash
# Inside VM
pip3 install azure-storage-blob azure-identity
```

```python
# save as /tmp/test_sdk.py and run: python3 /tmp/test_sdk.py
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient

STORAGE_ACCOUNT = "storetask07<suffix>"

# DefaultAzureCredential checks:
# 1. Env vars (AZURE_CLIENT_ID etc.) → 2. Managed Identity → 3. Azure CLI → ...
# Inside a VM with managed identity, step 2 is used automatically
credential = DefaultAzureCredential()

client = BlobServiceClient(
    account_url=f"https://{STORAGE_ACCOUNT}.blob.core.windows.net",
    credential=credential
)

# Upload
blob_client = client.get_blob_client(container="uploads", blob="sdk-test.txt")
blob_client.upload_blob("Hello from SDK using Managed Identity", overwrite=True)

# Download and print
data = blob_client.download_blob().readall()
print(data.decode())
# Expected: Hello from SDK using Managed Identity
```

---

## RBAC Scope Levels — Where to Assign

You can assign the role at different scopes. Narrower = better:

```
Subscription scope  ← VM can access ALL storage accounts in ALL RGs — too broad
    └── RG scope    ← VM can access ALL storage accounts in rg-storage — still broad
        └── Resource scope  ← VM can access ONLY this one storage account ✅ best
```

```bash
# Resource scope (recommended — what we did in Step 4)
az role assignment create \
  --assignee $MI_PRINCIPAL_ID \
  --role "Storage Blob Data Contributor" \
  --scope $STORAGE_ID            # ← specific storage account ID

# RG scope (if VM needs access to multiple storage accounts in rg-storage)
RG_SCOPE="/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG_STORAGE"
az role assignment create \
  --assignee $MI_PRINCIPAL_ID \
  --role "Storage Blob Data Contributor" \
  --scope $RG_SCOPE
```

---

## Common Roles for Storage

| Role | Can do |
|---|---|
| `Storage Blob Data Reader` | Read blobs, list containers |
| `Storage Blob Data Contributor` | Read + write + delete blobs |
| `Storage Blob Data Owner` | Full control including ACL management |
| `Storage Queue Data Contributor` | Read + write queue messages |
| `Storage Table Data Contributor` | Read + write table entities |
| `Storage Account Contributor` | Manage the account (keys, settings) but NOT data plane |

> `Storage Account Contributor` does NOT grant blob read/write — it's a management-plane
> role. Always use the `Storage Blob Data *` roles for data access.

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `AuthorizationPermissionMismatch` | Role not propagated yet | Wait 2 min, retry |
| `This request is not authorized` | Wrong role or wrong scope | `az role assignment list --scope $STORAGE_ID` |
| `az login --identity` fails | MI not enabled | `az vm identity show` — must return principalId |
| `MSIEndpointNotFound` | Not running inside Azure VM | MI only works from inside Azure resources |
| Container create fails with AuthError | Your own account lacks blob role | Assign yourself `Storage Blob Data Contributor` on the account |

---

## Cleanup

```bash
az group delete --name $RG_VM      --yes --no-wait
az group delete --name $RG_STORAGE --yes --no-wait
```

---

## Azure Portal — Manual Steps

Use these if you prefer the console over CLI. Resource names match the lab (`rg-vm`, `rg-storage`, `vm-cross-rg`, etc.).

### Step 0 — Create both resource groups

1. Open [Azure Portal](https://portal.azure.com/) → **Resource groups** → **Create**.
2. Create **`rg-vm`**, Region **South India** → **Review + create**.
3. Repeat for **`rg-storage`** (same region).

> Cross-RG access uses **RBAC scope on the resource**, not the resource group. Two RGs are only to show the VM and storage live in different groups.

### Step 1 — Storage account in rg-storage

1. **Resource groups** → **`rg-storage`** → **Create** → **Storage account**.
2. Name: globally unique (e.g. **`storetask07xxxxx`**), Region **South India**, **Standard LRS**, **StorageV2**.
3. **Advanced**: blob public access **Disabled**, minimum TLS **1.2**.
4. **Networking**: **Public network access** **Enabled** (or **Enabled from all networks**) for this lab — no private endpoint required.
5. **Create**.
6. Open the account → **Data storage** → **Containers** → **+ Container** → name **`uploads`** → **Create**.

If container create fails: **Access control (IAM)** on the storage account → assign yourself **Storage Blob Data Contributor**, then retry.

### Step 2 — VNet, subnet, NSG, VM in rg-vm

**Virtual network**

1. **Resource groups** → **`rg-vm`** → **Create** → **Virtual network**.
2. Name **`vnet-task07`**, address space **`10.10.0.0/16`**, subnet **`subnet-backend`** **`10.10.2.0/24`** → **Create**.

**NSG (SSH for lab)**

1. **Network security groups** → **Create** → **`nsg-vm`** in **`rg-vm`**.
2. **Inbound security rules** → **Add**: Name **`allow-ssh`**, Source **Any** or **Your IP**, Port **22**, **Allow**, Priority **100**.

**Virtual machine**

1. **Virtual machines** → **Create**.
2. RG **`rg-vm`**, Name **`vm-cross-rg`**, Region **South India**, Image **Ubuntu Server 22.04 LTS**, Size **Standard B2ts v2**.
3. **Networking**: **`vnet-task07`** / **`subnet-backend`**, Public IP **Create new** (`pip-vm-cross-rg`), NSG **`nsg-vm`**.
4. **Inbound ports**: allow **SSH (22)** (or rely on NSG rule above).
5. **Management** → **System assigned managed identity**: **On** (optional here; Step 3 enables it if off).
6. **Administrator account**: **`azureuser`**, SSH keys or password.
7. **Create**. Copy **Public IP** from VM **Overview**.

### Step 3 — Enable system-assigned managed identity

1. **Virtual machines** → **`vm-cross-rg`** (in **`rg-vm`**).
2. **Security** → **Identity**.
3. **System assigned** → **Status** **On** → **Save**.
4. Copy **Object (principal) ID** — this is `MI_PRINCIPAL_ID`.

> The VM can request Entra tokens after this step, but has **no** storage permissions until Step 4.

### Step 4 — RBAC on storage account (cross-RG)

Role is on the storage account in **`rg-storage`**; principal is the VM identity in **`rg-vm`**.

1. **Storage accounts** → your account in **`rg-storage`**.
2. **Access control (IAM)** → **Add** → **Add role assignment**.
3. **Role**: **Storage Blob Data Contributor** → **Next**.
4. **Assign access to**: **Managed identity** → **+ Select members**.
5. **Managed identity** type: **Virtual machine** → select **`vm-cross-rg`** → **Select**.
6. **Review + assign** (twice).

Verify: **IAM** → **Role assignments** → filter **Storage Blob Data Contributor** → **`vm-cross-rg`** listed. Wait 1–2 minutes if the VM test fails at first.

Optional — assign yourself the same role on the storage account if you need to create containers or browse blobs from the portal as your user.

### Step 5 — Test cross-RG access from the VM

1. SSH: `ssh azureuser@<VM-public-IP>`.
2. Install Azure CLI: `curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash`
3. `az login --identity`
4. `az account show --query user -o json` — expect `"type": "servicePrincipal"` and managed identity info.
5. Upload/list/download to container **`uploads`** with `--auth-mode login` (same commands as [Step 5](#step-5--test-cross-rg-access-from-inside-the-vm)); use your real storage account name.

Confirm in portal: storage account → **Containers** → **`uploads`** → blob **`cross-rg-test.txt`** appears.

### Step 6 — Prove access is identity-based

1. On the VM: `az logout`
2. Run `az storage blob list` with `--auth-mode login` — expect login / authorization error.
3. Run `az login --identity` again — list/upload works. Proves keys were not required.

### Step 7 — Python SDK (optional)

1. On the VM: `pip3 install azure-storage-blob azure-identity`
2. Run the Python sample from [Step 7](#step-7--use-with-python-sdk--production-pattern) — `DefaultAzureCredential()` uses managed identity without `az login` in app code.

---

## Cleanup (Portal)

1. **Resource groups** → delete **`rg-vm`** and **`rg-storage`** (or delete subscription lab resources in one go if nothing else uses them).
2. Confirm deletion of VMs, storage, and public IPs.
