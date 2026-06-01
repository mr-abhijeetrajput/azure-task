# Phase 05 — APIM Provisioning + TLS Custom Domain

> **Lab:** APIM 3 — Public APIM → Private AGW → AKS (httpbin)
> **Source:** [readme.md](../readme.md) → Step 2, Step 3

> ⏱ **APIM creation takes 30–45 minutes.** Start it and work on Phase 06 in parallel.

---

## Overview

- Deploy APIM in **External** VNet mode so the gateway has a public IP
- Attach a custom domain `api.abhijeetrajput.life` with a Let's Encrypt TLS certificate

### Why APIM is public here

In External mode, the gateway has a public IP. Clients call `https://api.abhijeetrajput.life`
which resolves to this public IP. APIM then forwards requests internally to AGW at `10.0.3.4`.

---

## 5.1 Create public IP for APIM gateway

> **Why a separate step:** Azure requires the Public IP to exist — and to have a **DNS label** —
> before you can select it in the APIM creation wizard. If you skip this, provisioning fails with:
> `Public IP Address resource must have a Fully Qualified Domain Name of an A DNS record associated.`
>
> Always create a dedicated IP in `rg-myapp` — never reuse the AKS-managed IP (`MC_*` RG).

```bash
az network public-ip create \
  --name $PIP_APIM \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Standard \
  --allocation-method Static \
  --dns-name apim-myapp-pub

# Verify FQDN assigned
az network public-ip show \
  --resource-group $RESOURCE_GROUP \
  --name $PIP_APIM \
  --query "{IP:ipAddress, FQDN:dnsSettings.fqdn}" -o table
# Expected: IP: 20.x.x.x   FQDN: apim-myapp-pub.southindia.cloudapp.azure.com
```

---

## 5.2 Create APIM (External VNet mode)

**Portal:** `API Management` → `Create`

| Tab | Field | Value |
|---|---|---|
| Basics | Resource name | `apim-myapp-pub` |
| Basics | Pricing tier | `Developer` |
| Basics | **Availability zones** | **None / uncheck all** ← Developer tier does not support zones |
| Basics | Virtual network | `Virtual network` |
| Basics | **Type** | **`External`** |
| Basics | VNet | `vnet-myapp` |
| Basics | Subnet | `snet-apim` |
| Basics | **Public IP Address** | **`pip-apim-myapp-pub`** |
| Managed Identity | **System assigned** | **`On`** ← required for Key Vault cert rotation |

**CLI:**
```bash
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

az apim create \
  --resource-group $RESOURCE_GROUP \
  --name $APIM_NAME \
  --location $LOCATION \
  --publisher-name "My Company" \
  --publisher-email admin@abhijeetrajput.life \
  --sku-name Developer \
  --virtual-network-type External \
  --virtual-network-id /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Network/virtualNetworks/$VNET_NAME \
  --subnet-name $APIM_SUBNET \
  --public-ip-address $PIP_APIM \
  --enable-managed-identity
# ⏱ 30–45 minutes
```

---

## 5.3 Note APIM public and private IPs

```bash
# Public gateway IP (→ Hostinger A record in Phase 07)
APIM_PUBLIC_IP=$(az apim show \
  --resource-group $RESOURCE_GROUP \
  --name $APIM_NAME \
  --query "publicIpAddresses[0]" -o tsv)
echo "APIM public IP: $APIM_PUBLIC_IP"

# Private IP (should be 10.0.2.4)
az apim show \
  --resource-group $RESOURCE_GROUP \
  --name $APIM_NAME \
  --query "privateIpAddresses[0]" -o tsv
```

---

## 5.4 Get TLS certificate via Let's Encrypt (DNS challenge)

> **Why DNS challenge:** APIM is inside a VNet — Let's Encrypt cannot reach the domain over HTTP.
> DNS challenge adds a TXT record in Hostinger instead — no public server needed.

```bash
# Install certbot (WSL / Ubuntu / macOS)
sudo apt update && sudo apt install certbot -y

# Request cert — DNS challenge
sudo certbot certonly \
  --manual \
  --preferred-challenges dns \
  -d api.abhijeetrajput.life
# Certbot pauses and prints a TXT token — DO NOT press Enter yet
```

In Hostinger hPanel → Domains → `abhijeetrajput.life` → DNS/Nameservers → Add Record:

| Type | Name | Value | TTL |
|---|---|---|---|
| `TXT` | `_acme-challenge.api` | `<token certbot printed>` | `300` |

```bash
# Verify propagation — wait until this returns the token
dig TXT _acme-challenge.api.abhijeetrajput.life +short
# Only press Enter in certbot once the token appears here
```

---

## 5.5 Export cert as PFX

```bash
sudo openssl pkcs12 -export \
  -in /etc/letsencrypt/live/api.abhijeetrajput.life/fullchain.pem \
  -inkey /etc/letsencrypt/live/api.abhijeetrajput.life/privkey.pem \
  -out ~/api.abhijeetrajput.life.pfx \
  -passout pass:YourPFXPassword

# Verify the PFX is valid — no output = good
openssl pkcs12 -in ~/api.abhijeetrajput.life.pfx \
  -passin pass:YourPFXPassword -noout

# Copy to Windows if using WSL
cp ~/api.abhijeetrajput.life.pfx /mnt/c/Users/<your-username>/Desktop/
```

> **Cert expiry:** Let's Encrypt certs expire in **90 days**. Re-export a new PFX and re-upload
> to APIM when it nears expiry. For production, use Key Vault with auto-rotation.

---

## 5.6 Upload certificate to APIM + configure custom domain

**Portal:** `apim-myapp-pub` → `Deployment + infrastructure` → `Custom domains` → `+ Add`

| Field | Value |
|---|---|
| Type | `Gateway` |
| Hostname | `api.abhijeetrajput.life` |
| Certificate | **Custom** → upload `api.abhijeetrajput.life.pfx` |
| Certificate password | `YourPFXPassword` |
| Negotiate client certificate | Off |
| Default SSL binding | **On** |

Click **Save** (3–5 min).

**CLI alternative:**
```bash
CERT_B64=$(base64 -w 0 ~/api.abhijeetrajput.life.pfx)

az apim update \
  --resource-group $RESOURCE_GROUP \
  --name $APIM_NAME \
  --hostname-configurations '[{
    "type": "Proxy",
    "hostName": "api.abhijeetrajput.life",
    "negotiateClientCertificate": false,
    "defaultSslBinding": true,
    "certificatePassword": "YourPFXPassword",
    "encodedCertificate": "'"$CERT_B64"'"
  }]'
```

---

## 5.7 Verify custom domain is active

```bash
curl -sk -o /dev/null -w "HTTP %{http_code}\n" \
  https://api.abhijeetrajput.life/
# Expected: HTTP 401  ← APIM responded ✅
# SSL error → cert not yet saved or Default SSL binding not On
```

---

## Phase 05 complete? ⬜ APIM provisioned, custom domain returns 401.
