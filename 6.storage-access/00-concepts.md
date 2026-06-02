# Storage Access from VM — Concepts

> Two ways to securely connect a VM to an Azure Storage Account.
> Read this before running the step-by-step labs:
> - [Service Endpoint lab](01-service-endpoint.md)
> - [Private Endpoint lab](02-private-endpoint.md)

---

## Table of Contents

1. [The Problem — why default access is risky](#1-the-problem)
2. [Service Endpoint — how it works](#2-service-endpoint)
3. [Private Endpoint — how it works](#3-private-endpoint)
4. [Side-by-side comparison](#4-comparison)
5. [Which one should you use?](#5-which-one-to-use)

---

## 1. The Problem

By default, a storage account is reachable from the public internet:

```
VM (10.10.2.5)
     │
     │ DNS: mystorageacct.blob.core.windows.net → 52.x.x.x  (public IP)
     │ Traffic leaves VNet → goes over internet
     ▼
Azure Storage (public endpoint — anyone on internet can attempt access)
```

This means:
- Traffic travels over the internet (even if both VM and storage are in Azure)
- The storage public endpoint is exposed — only auth keys/RBAC prevent access
- Cannot lock down storage to "only my VNet"

Both Service Endpoint and Private Endpoint solve this — in different ways.

---

## 2. Service Endpoint

### What it does

Enables a subnet to send traffic to a PaaS service (like Storage) **via the Azure backbone**
instead of over the public internet. The destination is still the service's **public IP**,
but traffic never leaves Azure's internal network.

```
WITHOUT Service Endpoint:
  VM (10.10.2.5) ──public internet──► Storage public IP (52.x.x.x)

WITH Service Endpoint:
  VM (10.10.2.5) ──Azure backbone──► Storage public IP (52.x.x.x)
                                      (traffic never touches internet)
```

### What changes

| Thing | Before | After |
|-------|--------|-------|
| Traffic path | Internet | Azure backbone |
| DNS resolution | Public IP | Still public IP (no change) |
| Private IP created | No | No |
| Storage firewall | Any source | Locked to your subnet only |

### How the storage firewall knows it's your subnet

When you enable `Microsoft.Storage` service endpoint on a subnet, Azure presents the
**subnet's identity** (not a raw IP) to the storage firewall. You then add a network
rule: "allow this subnet." All other sources (including other internet IPs) get denied
if you set `default-action Deny`.

### Limitations

- Works only in the **same Azure region** as the storage account
- Not accessible from **on-premises** (VPN/ExpressRoute) — service endpoints don't
  propagate across gateways
- Storage account still has a public IP — you are relying on the firewall rule, not
  eliminating public exposure entirely
- Free to use

---

## 3. Private Endpoint

### What it does

Injects a **private NIC with a private IP** into your VNet that represents the storage
account. Traffic from your VM goes to this private IP — it never leaves the VNet and
never touches a public IP.

```
WITHOUT Private Endpoint:
  VM (10.10.2.5)
       │ DNS: mystorageacct.blob.core.windows.net → 52.x.x.x (public)
       └──────────────────────────────────────────────────────►  Storage (public IP)

WITH Private Endpoint:
  VM (10.10.2.5)
       │ DNS: mystorageacct.blob.core.windows.net → 10.10.2.20 (private!)
       └────────────────────────────────────────►  Private Endpoint NIC (10.10.2.20)
                                                           │
                                                Azure internal network
                                                           │
                                                     Storage backend
```

### What changes

| Thing | Before | After |
|-------|--------|-------|
| Traffic path | Internet / backbone | Fully inside VNet |
| DNS resolution | Public IP | Private IP (via Private DNS Zone) |
| Private IP created | No | Yes — NIC injected into your subnet |
| Storage public access | Enabled | Can be fully disabled |
| On-prem access via VPN | No | Yes |

### Why DNS is the critical piece

Your VM's code calls `mystorageacct.blob.core.windows.net`. Without DNS magic, that still
resolves to the public IP. You must set up a **Private DNS Zone** linked to your VNet so
that inside the VNet, that hostname resolves to the private IP instead.

```
Azure Private DNS Zone: privatelink.blob.core.windows.net
A record: mystorageacct → 10.10.2.20

VM does DNS lookup:
  mystorageacct.blob.core.windows.net
  → CNAME: mystorageacct.privatelink.blob.core.windows.net  (Azure adds this automatically)
  → A: 10.10.2.20  (from your Private DNS Zone)
  → Traffic goes to 10.10.2.20 inside VNet ✅
```

No change to your app code at all.

### Cost

~$7–10/month per private endpoint + data processing charges.
Each sub-resource (blob, file, queue, table) needs its own endpoint if you want all private.

---

## 4. Comparison

| Feature | Service Endpoint | Private Endpoint |
|---------|-----------------|-----------------|
| Traffic path | Azure backbone → public IP | Fully inside VNet → private IP |
| DNS change needed | No | Yes (Private DNS Zone) |
| Private IP created | No | Yes (NIC in your subnet) |
| Storage public IP exposed | Yes (firewall protects) | No (can fully disable public) |
| Cross-region access | Same region only | Any region |
| On-prem (VPN/ExpressRoute) | No | Yes |
| Cost | Free | ~$7–10/month per endpoint |
| Setup complexity | Low | Medium |
| Security level | Good | Best |
| Works with NSG on PE subnet | N/A | Yes |

---

## 5. Which One to Use?

```
Is this a dev/test environment?
  └─ Yes → Service Endpoint  (free, fast, good enough)
  └─ No  → continue...

Does on-prem (VPN/ExpressRoute) need to reach storage?
  └─ Yes → Private Endpoint  (service endpoints don't cross gateways)
  └─ No  → continue...

Is the storage account cross-region from the VM?
  └─ Yes → Private Endpoint  (service endpoints are region-scoped)
  └─ No  → continue...

Do compliance requirements demand zero public exposure?
  └─ Yes → Private Endpoint  (disable public access entirely)
  └─ No  → Service Endpoint is fine for most cases
```

**Rule of thumb:** Production workloads with sensitive data → Private Endpoint.
Dev/test or simple same-region workloads → Service Endpoint.

---

## Azure Portal — Where to Find Each Setting

Reference map for the two labs. Full click-by-click steps are at the bottom of each lab guide.

### Service Endpoint (see [01-service-endpoint.md](01-service-endpoint.md))

| What | Portal path |
|------|-------------|
| Enable service endpoint on subnet | **Virtual networks** → your VNet → **Subnets** → subnet → **Service endpoints** → add **Microsoft.Storage** |
| Storage firewall — allow subnet | **Storage account** → **Networking** → **Enabled from selected virtual networks** → **Add** your VNet/subnet |
| Default deny | Same page → **Default action**: **Deny** |
| VM managed identity | **Virtual machines** → VM → **Security** → **Identity** → System assigned **On** |
| Blob data RBAC | **Storage account** → **Access control (IAM)** → role **Storage Blob Data Contributor** → assign VM identity |

### Private Endpoint (see [02-private-endpoint.md](02-private-endpoint.md))

| What | Portal path |
|------|-------------|
| PE subnet policy | **Virtual networks** → **Subnets** → PE subnet → **Private endpoint network policy**: **Disabled** |
| Create private endpoint | **Storage account** → **Networking** → **Private endpoint connections** → **+ Private endpoint** |
| Private DNS zone | **Private DNS zones** → zone name **`privatelink.blob.core.windows.net`** |
| Link zone to VNet | DNS zone → **Virtual network links** → **+ Add** (auto-registration **off**) |
| A record for storage | DNS zone → **Record sets** → **A** record = storage account name → PE private IP |
| Disable public access | **Storage account** → **Networking** → **Public network access**: **Disabled** |
| Approve PE (if pending) | **Storage account** → **Networking** → **Private endpoint connections** → **Approve** |

### Quick comparison in the portal

| Check | Service Endpoint lab | Private Endpoint lab |
|-------|---------------------|----------------------|
| Subnet has | **Microsoft.Storage** service endpoint | Dedicated **subnet-pe** + PE policy disabled |
| Storage networking | VNet rule + default **Deny** | Private endpoint + public access **Disabled** |
| DNS | No private DNS zone needed | **privatelink.blob.core.windows.net** zone required |
| VM identity + RBAC | Same in both labs | Same in both labs |
