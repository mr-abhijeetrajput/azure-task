# Storage Access via Private Endpoint — Step-by-Step Lab

> **Goal:** VM in `subnet-backend` accesses a storage account via a Private Endpoint.
> A private NIC with a private IP is injected into your VNet. DNS inside the VNet
> resolves the storage hostname to this private IP. Storage public access is fully
> disabled. Traffic never leaves the VNet.

---

## Architecture

```
VNet (10.10.0.0/16)
┌──────────────────────────────────────────────────────────────────────┐
│                                                                      │
│  subnet-backend (10.10.2.0/24)      subnet-pe (10.10.3.0/24)        │
│  ┌─────────────────────────┐        ┌──────────────────────────────┐ │
│  │  vm-backend             │        │  Private Endpoint NIC        │ │
│  │  10.10.2.4              │        │  10.10.3.5                   │ │
│  │                         │        │  (represents the storage     │ │
│  │  DNS lookup:            │        │   account inside your VNet)  │ │
│  │  mystorageacct...       │        └──────────────┬───────────────┘ │
│  │    → 10.10.3.5 ✅       │                       │                 │
│  └────────────┬────────────┘                       │                 │
│               │                                    │                 │
│               └──────── HTTPS to 10.10.3.5 ───────►│                 │
│                          (stays inside VNet)       │                 │
│                                                    │ Azure internal  │
│  Azure Private DNS Zone (linked to this VNet)      │ network         │
│  privatelink.blob.core.windows.net                 │                 │
│  A: mystorageacct → 10.10.3.5                      │                 │
│                                                    ▼                 │
└────────────────────────────────────────────────────────────────────── ┘
                                              Storage Account backend
                                              Public access: DISABLED
```

---

## DNS Resolution — Full Flow

```
1. vm-backend makes a request to:
   mystorageacct.blob.core.windows.net

2. Azure DNS resolves:
   mystorageacct.blob.core.windows.net
     → CNAME: mystorageacct.privatelink.blob.core.windows.net
       (Azure adds this CNAME automatically when PE is created)

3. Private DNS Zone resolves:
   mystorageacct.privatelink.blob.core.windows.net
     → A: 10.10.3.5  (private endpoint NIC IP)

4. VM connects to 10.10.3.5 — traffic stays inside VNet ✅

From OUTSIDE the VNet (your laptop):
   mystorageacct.blob.core.windows.net
     → CNAME: mystorageacct.privatelink.blob.core.windows.net
     → A: 52.x.x.x  (public IP — because no Private DNS Zone linked)
     → Storage firewall rejects: public access is disabled ✅
```

---

## Environment Variables

Run at the start of every session:

```bash
RESOURCE_GROUP="rg-task06"
VNET_NAME="vnet-task06"
LOCATION="southindia"
STORAGE_ACCOUNT="mystorageacct$RANDOM"   # must be globally unique
```

---

## Step 0 — Create Resource Group, VNet, and Subnets

> Skip if already done. You need two subnets: one for the VM, one dedicated for the PE.

```bash
az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION

az network vnet create \
  --resource-group $RESOURCE_GROUP \
  --name $VNET_NAME \
  --location $LOCATION \
  --address-prefixes 10.10.0.0/16

# Subnet for VM
az network vnet subnet create \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name subnet-backend \
  --address-prefixes 10.10.2.0/24

# Dedicated subnet for Private Endpoint
# A /27 or /28 is enough — PEs only need a few IPs
az network vnet subnet create \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name subnet-pe \
  --address-prefixes 10.10.3.0/24

# Required on any subnet that hosts Private Endpoints
az network vnet subnet update \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name subnet-pe \
  --disable-private-endpoint-network-policies true
```

> Without `--disable-private-endpoint-network-policies`, private endpoint creation fails.

---

## Step 1 — Create the Storage Account

```bash
az storage account create \
  --resource-group $RESOURCE_GROUP \
  --name $STORAGE_ACCOUNT \
  --location $LOCATION \
  --sku Standard_LRS \
  --kind StorageV2 \
  --allow-blob-public-access false \
  --min-tls-version TLS1_2

echo "Storage account: $STORAGE_ACCOUNT"

# Create a blob container (disable public network access in Step 6, after PE + DNS work)
az storage container create \
  --account-name $STORAGE_ACCOUNT \
  --name data \
  --auth-mode login
```

> Public blob access is off, but the storage **endpoint** is still reachable from the internet
> until Step 6. We lock that down only after the private endpoint and DNS are working.

---

## Step 2 — Create the Private Endpoint

This creates a NIC in `subnet-pe` that represents the storage account's blob endpoint.
The `--group-id blob` targets the blob service specifically.

```bash
# Get storage account resource ID
STORAGE_ID=$(az storage account show \
  --resource-group $RESOURCE_GROUP \
  --name $STORAGE_ACCOUNT \
  --query id -o tsv)

# Create the private endpoint
az network private-endpoint create \
  --resource-group $RESOURCE_GROUP \
  --name pe-storage-blob \
  --location $LOCATION \
  --vnet-name $VNET_NAME \
  --subnet subnet-pe \
  --private-connection-resource-id $STORAGE_ID \
  --group-id blob \
  --connection-name pe-storage-blob-conn
```

Verify the private endpoint connection is approved:

```bash
az network private-endpoint show \
  --resource-group $RESOURCE_GROUP \
  --name pe-storage-blob \
  --query "privateLinkServiceConnections[0].privateLinkServiceConnectionState" \
  -o json

# Expected:
# {
#   "actionsRequired": "None",
#   "description": "Auto-Approved",
#   "status": "Approved"
# }
```

Check what private IP was assigned:

```bash
az network private-endpoint show \
  --resource-group $RESOURCE_GROUP \
  --name pe-storage-blob \
  --query "customDnsConfigs[].{FQDN:fqdn, IP:ipAddresses[0]}" \
  -o table
# Example output:
# FQDN                                              IP
# ────────────────────────────────────────────────  ──────────
# mystorageacct.blob.core.windows.net               10.10.3.5
```

Save the private IP for the DNS step:

```bash
PE_PRIVATE_IP=$(az network private-endpoint show \
  --resource-group $RESOURCE_GROUP \
  --name pe-storage-blob \
  --query "customDnsConfigs[0].ipAddresses[0]" -o tsv)

echo "Private Endpoint IP: $PE_PRIVATE_IP"
```

---

## Step 3 — Create Private DNS Zone

The DNS zone name MUST match exactly — this is what Azure uses to intercept resolution:

```bash
az network private-dns zone create \
  --resource-group $RESOURCE_GROUP \
  --name "privatelink.blob.core.windows.net"
```

---

## Step 4 — Link DNS Zone to the VNet

Without this link, VMs in the VNet will not use the private DNS zone for lookups:

```bash
az network private-dns link vnet create \
  --resource-group $RESOURCE_GROUP \
  --zone-name "privatelink.blob.core.windows.net" \
  --name link-vnet-to-storage \
  --virtual-network $VNET_NAME \
  --registration-enabled false
```

> `--registration-enabled false` — we don't want VMs to auto-register their names
> into this zone. This zone is only for the storage account A record.

---

## Step 5 — Create DNS A Record

Add an A record that maps the storage account hostname to the private endpoint IP:

```bash
az network private-dns record-set a create \
  --resource-group $RESOURCE_GROUP \
  --zone-name "privatelink.blob.core.windows.net" \
  --name $STORAGE_ACCOUNT

az network private-dns record-set a add-record \
  --resource-group $RESOURCE_GROUP \
  --zone-name "privatelink.blob.core.windows.net" \
  --record-set-name $STORAGE_ACCOUNT \
  --ipv4-address $PE_PRIVATE_IP
```

Verify the DNS record:

```bash
az network private-dns record-set a show \
  --resource-group $RESOURCE_GROUP \
  --zone-name "privatelink.blob.core.windows.net" \
  --name $STORAGE_ACCOUNT \
  --query "aRecords[].ipv4Address" -o tsv
# Expected: 10.10.3.5  (your PE private IP)
```

> **Tip:** Azure Portal can do steps 3–5 automatically during PE creation.
> When prompted "Integrate with private DNS zone", select Yes and pick the zone.
> The portal creates the zone, link, and A record in one step.

---

## Step 6 — Disable Public Access on Storage Account

Now that the private endpoint is in place, turn off all public access:

```bash
az storage account update \
  --resource-group $RESOURCE_GROUP \
  --name $STORAGE_ACCOUNT \
  --public-network-access Disabled
```

Verify:

```bash
az storage account show \
  --resource-group $RESOURCE_GROUP \
  --name $STORAGE_ACCOUNT \
  --query "publicNetworkAccess" -o tsv
# Expected: Disabled
```

---

## Step 7 — Create VM in subnet-backend

```bash
az network nsg create \
  --resource-group $RESOURCE_GROUP \
  --name nsg-backend \
  --location $LOCATION

az network nsg rule create \
  --resource-group $RESOURCE_GROUP \
  --nsg-name nsg-backend \
  --name allow-ssh \
  --priority 100 \
  --source-address-prefixes Internet \
  --destination-port-ranges 22 \
  --protocol TCP \
  --access Allow \
  --direction Inbound

az vm create \
  --resource-group $RESOURCE_GROUP \
  --name vm-backend \
  --location $LOCATION \
  --image Ubuntu2204 \
  --size Standard_B2ts_v2 \
  --vnet-name $VNET_NAME \
  --subnet subnet-backend \
  --nsg nsg-backend \
  --public-ip-address pip-vm-backend \
  --public-ip-sku Standard \
  --admin-username azureuser \
  --generate-ssh-keys \
  --assign-identity

VM_PUBLIC_IP=$(az vm show \
  --resource-group $RESOURCE_GROUP \
  --name vm-backend \
  --show-details --query publicIps -o tsv)

echo "VM public IP: $VM_PUBLIC_IP"
```

---

## Step 8 — Assign RBAC (Managed Identity)

```bash
VM_PRINCIPAL_ID=$(az vm identity show \
  --resource-group $RESOURCE_GROUP \
  --name vm-backend \
  --query principalId -o tsv)

STORAGE_ID=$(az storage account show \
  --resource-group $RESOURCE_GROUP \
  --name $STORAGE_ACCOUNT \
  --query id -o tsv)

az role assignment create \
  --assignee $VM_PRINCIPAL_ID \
  --role "Storage Blob Data Contributor" \
  --scope $STORAGE_ID
```

---

## Step 9 — Test DNS Resolution from Inside the VM

```bash
ssh azureuser@$VM_PUBLIC_IP
```

Inside the VM, verify DNS resolves to the private IP (not a public `52.x.x.x`):

```bash
sudo apt-get install -y dnsutils

# Resolve storage hostname — must return private IP, not public IP
nslookup $STORAGE_ACCOUNT.blob.core.windows.net
# Expected output:
# Server: 168.63.129.16   (Azure DNS)
# Non-authoritative answer:
# Name: mystorageacct.privatelink.blob.core.windows.net
# Address: 10.10.3.5      ← private IP ✅  (NOT 52.x.x.x)

# OR use dig
dig $STORAGE_ACCOUNT.blob.core.windows.net
# Should show ANSWER with 10.10.3.5
```

> If you still see the public IP, wait 1–2 minutes for DNS propagation, then retry.
> Also check the Private DNS Zone link is correctly set to your VNet.

---

## Step 10 — Test Blob Access from Inside the VM

```bash
# Install Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Login with managed identity
az login --identity

STORAGE_ACCOUNT="<your-storage-account-name>"

# Upload a file
echo "Hello via Private Endpoint — no public IP involved" > /tmp/test.txt
az storage blob upload \
  --account-name $STORAGE_ACCOUNT \
  --container-name data \
  --name test.txt \
  --file /tmp/test.txt \
  --auth-mode login

# List blobs
az storage blob list \
  --account-name $STORAGE_ACCOUNT \
  --container-name data \
  --auth-mode login \
  --query "[].{Name:name, Size:properties.contentLength}" \
  -o table

# Download it back
az storage blob download \
  --account-name $STORAGE_ACCOUNT \
  --container-name data \
  --name test.txt \
  --file /tmp/downloaded.txt \
  --auth-mode login

cat /tmp/downloaded.txt
# Expected: Hello via Private Endpoint — no public IP involved
```

---

## Step 11 — Prove Public Access is Blocked

From your laptop (outside the VNet):

```bash
# DNS lookup from laptop — returns public IP (no private DNS zone linked to your laptop)
nslookup $STORAGE_ACCOUNT.blob.core.windows.net
# Returns: 52.x.x.x (public IP)

# Try to access storage — must FAIL even if you have correct credentials
az storage blob list \
  --account-name $STORAGE_ACCOUNT \
  --container-name data \
  --auth-mode login
# Expected error:
# (PublicAccessNotPermitted) Public access is not permitted on this storage account.
# OR (AuthorizationFailure) This request is not authorized to perform this operation.
# Reason: public network access is Disabled — only the private endpoint path works
```

---

## Common DNS Zone Names by Storage Sub-resource

If you need private access to other storage services (not just blob), create
separate private endpoints with the corresponding group-id and DNS zone:

| Sub-resource (--group-id) | Private DNS Zone |
|---------------------------|-----------------|
| `blob` | `privatelink.blob.core.windows.net` |
| `file` | `privatelink.file.core.windows.net` |
| `queue` | `privatelink.queue.core.windows.net` |
| `table` | `privatelink.table.core.windows.net` |
| `dfs` (ADLS Gen2) | `privatelink.dfs.core.windows.net` |

Each needs its own private endpoint, DNS zone, and A record.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `nslookup` returns public IP (52.x.x.x) | DNS zone not linked to VNet | Re-run Step 4; verify with `az network private-dns link vnet list` |
| Upload fails with `PublicAccessNotPermitted` from VM | DNS still resolving to public IP | Fix DNS first (see above) |
| PE state is `Pending` not `Approved` | Manual approval needed (cross-subscription) | Storage → Networking → Private endpoint connections → Approve |
| PE creation fails on subnet | Network policies not disabled | Re-run `--disable-private-endpoint-network-policies` on `subnet-pe` |
| `az login --identity` fails | Managed identity not enabled | Confirm `--assign-identity` on VM; `az vm identity show` |
| Container create fails with AuthError | Your account lacks blob data role | Assign yourself `Storage Blob Data Contributor` on the storage account |

### DNS still resolves to public IP inside VM

1. Check the Private DNS Zone is linked to the correct VNet:
   ```bash
   az network private-dns link vnet list \
     --resource-group $RESOURCE_GROUP \
     --zone-name "privatelink.blob.core.windows.net" \
     -o table
   ```
2. Check the A record exists and has the correct IP:
   ```bash
   az network private-dns record-set a list \
     --resource-group $RESOURCE_GROUP \
     --zone-name "privatelink.blob.core.windows.net" \
     -o table
   ```
3. Wait 1–2 minutes and retry nslookup.

### Blob upload fails with AuthorizationFailure

1. Check RBAC assignment propagated (can take up to 5 minutes):
   ```bash
   az role assignment list --scope $STORAGE_ID -o table
   ```
2. Confirm the VM's managed identity is enabled:
   ```bash
   az vm identity show -g $RESOURCE_GROUP -n vm-backend
   ```

### Private endpoint status is not Approved

```bash
az network private-endpoint-connection list \
  --resource-group $RESOURCE_GROUP \
  --name $STORAGE_ACCOUNT \
  --type Microsoft.Storage/storageAccounts \
  -o table
# If state is Pending, approve it:
az network private-endpoint-connection approve \
  --resource-group $RESOURCE_GROUP \
  --service-name $STORAGE_ACCOUNT \
  --name <connection-name> \
  --type Microsoft.Storage/storageAccounts \
  --description "Approved"
```

> When you create the PE and storage account in the same subscription, approval
> is automatic. Manual approval is only needed for cross-subscription setups.

---

## Summary

| Step | What it does |
|------|-------------|
| 1. Create storage account | The storage resource |
| 2. Create private endpoint | Injects a NIC (private IP) into your subnet |
| 3. Create Private DNS Zone | Container for the A record override |
| 4. Link DNS Zone to VNet | Makes VMs in this VNet use the zone |
| 5. Add A record | Maps storage hostname → private IP |
| 6. Disable public access | Eliminates public IP reachability entirely |
| 7–8. VM + RBAC | VM with managed identity for authentication |
| 9. Test DNS | Confirm hostname resolves to private IP inside VNet |
| 10. Test blob access | Confirm read/write works via private IP |
| 11. Prove public blocked | Confirm external access is rejected |

---

## Cleanup

```bash
az group delete --name $RESOURCE_GROUP --yes --no-wait
```

---

## Azure Portal — Manual Steps

Use these if you prefer the console over CLI. Names match the lab (`rg-task06`, `vnet-task06`, `pe-storage-blob`, etc.).

### Step 0 — Resource group, VNet, subnets

1. **Resource groups** → **Create** → **`rg-task06`**, Region **South India**.
2. **Virtual networks** → **Create** → **`vnet-task06`**, address space **`10.10.0.0/16`**.
3. Add subnets:
   - **`subnet-backend`**: **`10.10.2.0/24`** (VM)
   - **`subnet-pe`**: **`10.10.3.0/24`** (Private Endpoint)
4. Open **`subnet-pe`** → set **Private endpoint network policy** to **Disabled** (or **Network policies: Disabled**) → **Save**.

> If this policy stays enabled, private endpoint creation on the subnet fails.

### Step 1 — Storage account + container

1. In **`rg-task06`** → **Storage account** → **Create**.
2. Name: globally unique, Region **South India**, **Standard LRS**, **StorageV2**, blob public access **off**, TLS **1.2**.
3. **Create**, then open the account → **Data storage** → **Containers** → **+ Container** → name **`data`** → **Create**.

> Leave **Public network access** enabled until Steps 2–5 (PE + DNS) work; disable in Step 6.

### Step 2 — Private endpoint

1. Storage account → **Networking** → **Private endpoint connections** → **+ Private endpoint**.
2. **Basics**: Name **`pe-storage-blob`**, Region **South India**, Resource group **`rg-task06`**.
3. **Resource**: Resource type **Microsoft.Storage/storageAccounts**, select your storage account, Target sub-resource **blob**.
4. **Virtual network**: **`vnet-task06`**, Subnet **`subnet-pe`**, integrate with private DNS zone: **Yes** (recommended — creates zone, link, and A record; skip manual Steps 3–5 if you use this).
5. If integrating DNS manually in Steps 3–5, choose **No** here.
6. **Review + create**.

Verify: private endpoint → **Overview** → connection state **Approved**; note **Private IP** (e.g. `10.10.3.5`).

### Step 3 — Private DNS zone (skip if integrated in Step 2)

1. **Private DNS zones** → **Create**.
2. Name: **`privatelink.blob.core.windows.net`** (exact name), Resource group **`rg-task06`** → **Create**.

### Step 4 — Link DNS zone to VNet (skip if integrated in Step 2)

1. Open zone **`privatelink.blob.core.windows.net`** → **Virtual network links** → **+ Add**.
2. Link name: **`link-vnet-to-storage`**, Virtual network: **`vnet-task06`**, **Auto-registration**: **No** → **OK**.

### Step 5 — DNS A record (skip if integrated in Step 2)

1. In the DNS zone → **Overview** → **+ Record set**.
2. Name: your **storage account name** (hostname only, not FQDN), Type **A**, TTL **3600**.
3. IP address: private endpoint IP from Step 2 → **OK**.

Verify: record set shows your storage name → private IP (e.g. `10.10.3.5`).

### Step 6 — Disable public network access

1. Storage account → **Networking** (or **Security + networking** → **Networking**).
2. **Public network access**: **Disabled** → **Save**.

Verify: **Public network access** shows **Disabled**.

### Step 7 — VM + managed identity

1. **Virtual machines** → **Create** → **`vm-backend`**, Ubuntu 22.04, **Standard B2ts v2**, RG **`rg-task06`**.
2. **Networking**: **`vnet-task06`** / **`subnet-backend`**, Public IP: **Create new** (e.g. **`pip-vm-backend`**) for lab SSH.
3. **Management** → **Identity** → **System assigned managed identity**: **On**.
4. **Inbound ports**: allow **SSH (22)** (or attach NSG **`nsg-backend`** with allow-ssh rule).
5. **Create**. Copy the VM **Public IP** from **Overview**.

### Step 8 — RBAC for managed identity

1. Storage account → **Access control (IAM)** → **Add role assignment**.
2. Role: **Storage Blob Data Contributor**.
3. **Assign access to**: **Managed identity** → select **Virtual machine** **`vm-backend`** → **Review + assign**.

> If identity was not enabled at create time: VM → **Identity** → System assigned **On** → Save, then assign role.

### Step 9 — Test DNS inside VM

1. SSH: `ssh azureuser@<VM-public-IP>`.
2. `sudo apt-get install -y dnsutils`
3. `nslookup <storage-account>.blob.core.windows.net`
4. Expect **Address** in `10.10.3.x` range (private), not `52.x.x.x`.

### Step 10 — Test blob access inside VM

1. Install Azure CLI on the VM.
2. `az login --identity`
3. Upload/list/download blobs in container **`data`** with `--auth-mode login` (same as CLI Step 10).

### Step 11 — Prove public access blocked

1. From your **laptop**, run `az storage blob list` (or Storage Explorer) against the account.
2. Expect **PublicAccessNotPermitted** or **AuthorizationFailure** — public path is disabled.

---

## Cleanup (Portal)

1. **Resource groups** → **`rg-task06`** → **Delete resource group** → confirm name → **Delete**.
