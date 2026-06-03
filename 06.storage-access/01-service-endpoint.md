# Storage Access via Service Endpoint — Step-by-Step Lab

> **Goal:** VM in `subnet-backend` accesses a private storage account using a
> Service Endpoint. Traffic stays on the Azure backbone. Storage firewall locks
> access to this subnet only. No private IP, no DNS change needed.

---

## Architecture

```
VNet (10.10.0.0/16)
┌──────────────────────────────────────────────────────┐
│                                                      │
│  subnet-backend (10.10.2.0/24)                       │
│  ┌────────────────────────────────────────────────┐  │
│  │  Service endpoint: Microsoft.Storage enabled   │  │
│  │                                                │  │
│  │  vm-backend (10.10.2.4)                        │  │
│  │  ● Uses storage SDK / az storage CLI           │  │
│  └──────────────────┬─────────────────────────────┘  │
│                     │                                │
│                     │ Azure backbone (NOT internet)   │
└─────────────────────┼────────────────────────────────┘
                      │
                      ▼
             Azure Storage Account
             mystorageacct.blob.core.windows.net
             Public IP: 52.x.x.x  (still used, but)
             Firewall rule: Allow subnet-backend only
             Default action: Deny all other
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

## Step 0 — Create Resource Group, VNet, and Subnet

> Skip if already done from a previous task. Adjust names to match your existing setup.

```bash
az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION

az network vnet create \
  --resource-group $RESOURCE_GROUP \
  --name $VNET_NAME \
  --location $LOCATION \
  --address-prefixes 10.10.0.0/16

az network vnet subnet create \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name subnet-backend \
  --address-prefixes 10.10.2.0/24
```

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
```

At this point the storage account is publicly accessible (default).
We will lock it down in Step 3.

---

## Step 2 — Enable Service Endpoint on the Subnet

This tells Azure: "when VMs in this subnet talk to Storage, route via backbone
and present the subnet's identity to the storage firewall."

```bash
az network vnet subnet update \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name subnet-backend \
  --service-endpoints Microsoft.Storage
```

Verify:

```bash
az network vnet subnet show \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name subnet-backend \
  --query "serviceEndpoints[].service" \
  -o tsv
# Expected output: Microsoft.Storage
```

---

## Step 3 — Lock the Storage Account to the Subnet Only

Add a network rule allowing only `subnet-backend`, then deny everything else:

```bash
# Add network rule: allow this specific subnet
az storage account network-rule add \
  --resource-group $RESOURCE_GROUP \
  --account-name $STORAGE_ACCOUNT \
  --vnet-name $VNET_NAME \
  --subnet subnet-backend

# Set default action to Deny (blocks all other sources)
az storage account update \
  --resource-group $RESOURCE_GROUP \
  --name $STORAGE_ACCOUNT \
  --default-action Deny
```

Verify the rules:

```bash
az storage account show \
  --resource-group $RESOURCE_GROUP \
  --name $STORAGE_ACCOUNT \
  --query "networkRuleSet" \
  -o json
# Expected:
# {
#   "defaultAction": "Deny",
#   "virtualNetworkRules": [
#     {
#       "virtualNetworkResourceId": "...subnet-backend...",
#       "action": "Allow",
#       "state": "Succeeded"
#     }
#   ]
# }
```

---

## Step 4 — Create VM in subnet-backend

```bash
# NSG — allow SSH from VNet (jump host access)
az network nsg create \
  --resource-group $RESOURCE_GROUP \
  --name nsg-backend \
  --location $LOCATION

az network nsg rule create \
  --resource-group $RESOURCE_GROUP \
  --nsg-name nsg-backend \
  --name allow-ssh-from-vnet \
  --priority 100 \
  --source-address-prefixes VirtualNetwork \
  --destination-port-ranges 22 \
  --protocol TCP \
  --access Allow \
  --direction Inbound

# Create VM (no public IP — private subnet)
az vm create \
  --resource-group $RESOURCE_GROUP \
  --name vm-backend \
  --location $LOCATION \
  --image Ubuntu2204 \
  --size Standard_B2ts_v2 \
  --vnet-name $VNET_NAME \
  --subnet subnet-backend \
  --nsg nsg-backend \
  --public-ip-address "" \
  --admin-username azureuser \
  --generate-ssh-keys
```

> If you need SSH access, create a bastion host or a public jump VM in another subnet.
> For lab purposes you can temporarily add a public IP to vm-backend.

---

## Step 5 — Assign RBAC so the VM can Authenticate to Storage

Service endpoints handle the **network path** (routing + firewall).
You still need **authentication** — the VM needs permission to read/write blobs.
Use Managed Identity so no keys are stored anywhere:

```bash
# Enable system-assigned managed identity on the VM
az vm identity assign \
  --resource-group $RESOURCE_GROUP \
  --name vm-backend

# Get the VM's principal ID
VM_PRINCIPAL_ID=$(az vm identity show \
  --resource-group $RESOURCE_GROUP \
  --name vm-backend \
  --query principalId -o tsv)

# Get the storage account resource ID
STORAGE_ID=$(az storage account show \
  --resource-group $RESOURCE_GROUP \
  --name $STORAGE_ACCOUNT \
  --query id -o tsv)

# Assign Storage Blob Data Contributor role to the VM's identity
az role assignment create \
  --assignee $VM_PRINCIPAL_ID \
  --role "Storage Blob Data Contributor" \
  --scope $STORAGE_ID
```

---

## Step 6 — Test Access from Inside the VM

SSH into vm-backend (via bastion or jump host), then run:

```bash
# Install Azure CLI if not present
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Login using managed identity (no password, no keys)
az login --identity

# Set your storage account name
STORAGE_ACCOUNT="<your-storage-account-name>"

# Create a test container
az storage container create \
  --account-name $STORAGE_ACCOUNT \
  --name testcontainer \
  --auth-mode login

# Upload a test file
echo "Hello from vm-backend via Service Endpoint" > /tmp/test.txt
az storage blob upload \
  --account-name $STORAGE_ACCOUNT \
  --container-name testcontainer \
  --name test.txt \
  --file /tmp/test.txt \
  --auth-mode login

# Download it back
az storage blob download \
  --account-name $STORAGE_ACCOUNT \
  --container-name testcontainer \
  --name test.txt \
  --file /tmp/downloaded.txt \
  --auth-mode login

cat /tmp/downloaded.txt
# Expected: Hello from vm-backend via Service Endpoint
```

---

## Step 7 — Verify the Service Endpoint is Working (not public internet)

Test from OUTSIDE the VNet to prove the firewall blocks it:

```bash
# From your local machine (not inside the VM) — this should FAIL
az storage blob list \
  --account-name $STORAGE_ACCOUNT \
  --container-name testcontainer \
  --auth-mode login
# Expected error: "This request is not authorized to perform this operation"
# Reason: your laptop's IP is not in the subnet-backend network rule
```

Check effective routes on the VM's NIC to confirm backbone routing:

```bash
NIC_NAME=$(az vm show -g $RESOURCE_GROUP -n vm-backend \
  --query "networkProfile.networkInterfaces[0].id" -o tsv | awk -F'/' '{print $NF}')

az network nic show-effective-route-table \
  --resource-group $RESOURCE_GROUP \
  --name $NIC_NAME \
  -o table
# Storage traffic goes via Azure backbone — no explicit route appears
# but the service endpoint tag ensures routing is via backbone
```

---

## Key Facts to Remember

| Item | Detail |
|------|--------|
| Service endpoint enables | Backbone routing + subnet identity presentation to storage firewall |
| DNS | No change — storage still resolves to public IP |
| Authentication | Still required (use Managed Identity or storage key — key not recommended) |
| Firewall rule | `az storage account network-rule add` + `--default-action Deny` |
| Cross-region | Does NOT work — endpoint and storage must be same region |
| On-prem access | Does NOT work via VPN/ExpressRoute |
| Cost | Free |

---

## Azure Portal — Manual Steps

Use these if you prefer the console over CLI. Resource names match the lab above (`rg-task06`, `vnet-task06`, etc.).

### Step 0 — Resource group, VNet, subnet

1. Open [Azure Portal](https://portal.azure.com/) → **Resource groups** → **Create**.
2. Name: **`rg-task06`**, Region: **South India** → **Review + create**.
3. Open **`rg-task06`** → **Create** → **Virtual network**.
4. Name: **`vnet-task06`**, Address space: **`10.10.0.0/16`**.
5. Add subnet **`subnet-backend`**, range **`10.10.2.0/24`** → **Create**.

### Step 1 — Storage account

1. In **`rg-task06`** → **Create** → **Storage account**.
2. Name: globally unique (e.g. **`mystorageacct1234555`**), Region: **South India**, Performance: **Standard**, Redundancy: **LRS**, Kind: **StorageV2 (general purpose v2)**.
3. **Advanced** → **Allow blob public access**: **Disabled**; **Minimum TLS**: **Version 1.2**.
4. **Create**. Note the exact storage account name.

### Step 2 — Service endpoint on subnet

1. Go to **Virtual networks** → **`vnet-task06`** → **Subnets** → **`subnet-backend`**.
2. Under **Service endpoints**, click **None** (or **+ Service endpoint**).
3. Select service **`Microsoft.Storage`** → **Save**.

Verify: reopen **`subnet-backend`** — **Service endpoints** should list **Microsoft.Storage**.

### Step 3 — Storage firewall (subnet only)

1. Open your **Storage account** → **Networking** (or **Security + networking** → **Networking**).
2. **Public network access**: leave **Enabled from all networks** for now (firewall will restrict).
3. Under **Firewalls and virtual networks**:
   - **Public network access** tab: set **Enabled from selected virtual networks and IP addresses**.
   - **Virtual networks** → **Add existing virtual network**.
   - Select **`vnet-task06`** / **`subnet-backend`** → **Add**.
4. Ensure **Default action** is **Deny** (blocks all sources except allowed VNets/IPs).
5. **Save**.

Verify: **Networking** shows **`subnet-backend`** under virtual network rules and default action **Deny**.

### Step 4 — VM + NSG

1. **Create** → **Virtual machine**.
2. Resource group: **`rg-task06`**, Name: **`vm-backend`**, Region: **South India**, Image: **Ubuntu Server 22.04 LTS**, Size: **Standard B2ts v2**.
3. **Networking** → Virtual network: **`vnet-task06`**, Subnet: **`subnet-backend`**.
4. **Public IP**: **None** (private VM) — or add a public IP temporarily for lab SSH.
5. **Inbound ports**: None (or configure NSG separately).
6. **Administrator account**: username **`azureuser`**, authentication per your preference.
7. **Create**.

**NSG (if not created with VM):**

1. **Network security groups** → create **`nsg-backend`** in **`rg-task06`**.
2. **Inbound security rules** → **Add**:
   - Name: **`allow-ssh-from-vnet`**, Source: **VirtualNetwork**, Destination port: **22**, Protocol **TCP**, Action **Allow**, Priority **100**.
3. Attach NSG to **`vm-backend`** NIC: VM → **Networking** → NIC → **Network security group** → **`nsg-backend`**.

### Step 5 — Managed identity + RBAC

**Enable system-assigned identity:**

1. **Virtual machines** → **`vm-backend`** → **Security** → **Identity**.
2. **System assigned** → Status **On** → **Save**.
3. Copy **Object (principal) ID**.

**Assign storage role:**

1. Open the **Storage account** → **Access control (IAM)**.
2. **Add** → **Add role assignment**.
3. Role: **Storage Blob Data Contributor** → **Next**.
4. **Assign access to**: **Managed identity** → **+ Select members**.
5. Choose **Virtual machine** → **`vm-backend`** → **Select** → **Review + assign** (twice).

### Step 6 — Test from inside the VM

1. Connect to **`vm-backend`** (Bastion, jump host, or public IP if you added one).
2. Install Azure CLI and run the same commands as [Step 6 — Test Access](#step-6--test-access-from-inside-the-vm) (`az login --identity`, container create, blob upload/download with `--auth-mode login`).

### Step 7 — Verify firewall blocks external access

1. From your **laptop** (Azure Cloud Shell or local CLI), run `az storage blob list` against the account with `--auth-mode login`.
2. Expect **authorization / network** error — your IP is not in **`subnet-backend`**.
3. Optional: VM → **Networking** → NIC → **Effective routes** to review routing (service endpoint uses backbone; no custom route required).

---

## Cleanup (Portal)

1. **Resource groups** → **`rg-task06`** → **Delete resource group** → type the name → **Delete**.
