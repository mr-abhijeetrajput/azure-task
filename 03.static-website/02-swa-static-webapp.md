# Static Website Hosting — Azure Static Web Apps + Custom DNS

> **Goal:** Deploy a frontend app (React / plain HTML) using Azure Static Web Apps (SWA),
> attach a custom domain (`app.abhijeetrajput.life`), and optionally lock direct access
> so only Azure Front Door can reach the app.
>
> **Cost:**
> - SWA Free plan → ✅ FREE (with GitHub CI/CD)
> - Custom Domain → ✅ FREE
> - SWA Standard plan (for Private Endpoint) → 💳 ~$9/month
> - Front Door Premium (for Private Link to SWA) → 💳 ~$330/month
>
> **How SWA is different from Storage static website:**
>
> | | Storage Static Website | Azure Static Web App |
> |-|------------------------|----------------------|
> | Use for | Pure HTML/CSS/JS — no build step | React, Vue, Angular, Next.js |
> | CI/CD | Manual upload | Auto-deploy from GitHub/ADO |
> | API backend | ❌ No | ✅ Azure Functions built-in |
> | Custom domain HTTPS | Needs Front Door | ✅ Built-in free SSL |
> | Private Endpoint | Not supported | ✅ Standard plan |
> | Staging environments | ❌ No | ✅ Per PR preview URLs |
>
> **Prerequisites:** Run `00-foundation-setup.md` first (resource group already exists).

---

## What you will build

```
OPTION A (Free — GitHub deploy):

  git push → GitHub Actions
       │
       ▼
  Azure Static Web App
  app.abhijeetrajput.life  ← built-in HTTPS, free managed cert
  (direct public access — anyone can reach it)


OPTION B (Paid — locked behind Front Door):

  User Browser
       │  https://app.abhijeetrajput.life
       │  CNAME → endpoint-task03.z01.azurefd.net
       ▼
  Azure Front Door Premium
  WAF + Private Link
       │
       ▼
  Azure Static Web App (public access: DISABLED)
  Direct URL → 403 Forbidden
  Only Front Door can reach it via Private Link
```

---

## Environment variables

```bash
RESOURCE_GROUP="rg-task01"
LOCATION="eastus2"           # SWA not available in all regions — eastus2 is reliable
SWA_NAME="swa-task03"
CUSTOM_DOMAIN="app.abhijeetrajput.life"
```

---

## Part 1 — Create Static Web App

### Option A — With GitHub (recommended, enables auto-deploy)

```bash
# First, fork or use any GitHub repo with an index.html or React app
# Then:
az staticwebapp create \
  --resource-group $RESOURCE_GROUP \
  --name $SWA_NAME \
  --location $LOCATION \
  --source https://github.com/<your-username>/<your-repo> \
  --branch main \
  --app-location "/" \
  --output-location "" \
  --login-with-github
```

> `--login-with-github` opens a browser for GitHub OAuth.
> Azure creates a GitHub Actions workflow file in your repo automatically.
> Every `git push` to `main` triggers a deploy — no manual upload needed.

### Option B — Without GitHub (manual / bring your own CI)

```bash
az staticwebapp create \
  --resource-group $RESOURCE_GROUP \
  --name $SWA_NAME \
  --location $LOCATION \
  --sku Free
```

> When source is not provided, SWA is created without CI/CD.
> You deploy manually using the SWA CLI or upload a zip.

Get the default hostname:

```bash
SWA_HOSTNAME=$(az staticwebapp show \
  --resource-group $RESOURCE_GROUP \
  --name $SWA_NAME \
  --query "defaultHostname" -o tsv)

echo "SWA default URL: https://$SWA_HOSTNAME"
# Example: https://swa-task03.azurestaticapps.net
```

---

## Part 2 — Deploy App Content (without GitHub)

If you chose Option B above, deploy content using the SWA CLI:

```bash
# Install SWA CLI
npm install -g @azure/static-web-apps-cli

# Create a sample app
mkdir -p ~/swa-app
cat << 'EOF' > ~/swa-app/index.html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Azure Static Web App</title>
  <style>
    body { font-family: sans-serif; max-width: 800px; margin: 80px auto; padding: 0 20px; }
    h1 { color: #0078d4; }
    .badge { background: #e3f2fd; color: #1565c0; padding: 4px 12px; border-radius: 4px; font-size: 14px; }
    .env { margin-top: 20px; background: #f5f5f5; padding: 16px; border-radius: 8px; font-family: monospace; }
  </style>
</head>
<body>
  <h1>Hello from Azure Static Web App 🚀</h1>
  <p><span class="badge">Hosted on Azure Static Web Apps</span></p>
  <p>Domain: <strong>app.abhijeetrajput.life</strong></p>
  <p>This app has built-in SSL, staging environments, and optional Azure Functions API.</p>
  <div class="env">
    <p>Unlike Storage static website, SWA supports:</p>
    <p>✅ React / Vue / Angular builds</p>
    <p>✅ GitHub Actions auto-deploy</p>
    <p>✅ Per-PR staging preview URLs</p>
    <p>✅ Built-in authentication (AAD, GitHub, Twitter)</p>
  </div>
</body>
</html>
EOF

# Get deployment token
DEPLOY_TOKEN=$(az staticwebapp secrets list \
  --resource-group $RESOURCE_GROUP \
  --name $SWA_NAME \
  --query "properties.apiKey" -o tsv)

# Deploy using SWA CLI
swa deploy ~/swa-app \
  --deployment-token $DEPLOY_TOKEN \
  --env production
```

Test:

```bash
curl -s https://$SWA_HOSTNAME
# Expected: your index.html
```

---

## Part 3 — Custom Domain with Built-in HTTPS

SWA gives you HTTPS on your custom domain for free — no Front Door needed.

### Step 1 — Add custom domain in Azure

```bash
az staticwebapp hostname set \
  --resource-group $RESOURCE_GROUP \
  --name $SWA_NAME \
  --hostname $CUSTOM_DOMAIN
```

Get the validation token:

```bash
az staticwebapp hostname show \
  --resource-group $RESOURCE_GROUP \
  --name $SWA_NAME \
  --hostname $CUSTOM_DOMAIN \
  --query "{Hostname:domainName, Status:status, ValidationToken:errorMessage}" \
  -o table
```

### Step 2 — Add DNS records

**For a subdomain like `app.abhijeetrajput.life`:**

| Type | Name | Value | TTL |
|------|------|-------|-----|
| CNAME | `app` | `swa-task03.azurestaticapps.net` | 60 |

> Azure validates the CNAME and automatically issues a free managed SSL cert.
> This takes 5–10 minutes after DNS propagation.

**For an apex domain like `abhijeetrajput.life` (root):**

| Type | Name | Value | TTL |
|------|------|-------|-----|
| TXT | `@` | `<validationToken from above>` | 60 |
| ALIAS/ANAME | `@` | `swa-task03.azurestaticapps.net` | 60 |

> CNAME on apex (`@`) is not allowed by DNS spec.
> Use ALIAS/ANAME records if your DNS provider supports them (Cloudflare, Route53 do).
> If not, use A record pointing to the SWA IP (not recommended — IP can change).

### Step 3 — Verify DNS propagation and cert issuance

```bash
# Verify CNAME resolves
dig CNAME app.abhijeetrajput.life +short
# Expected: swa-task03.azurestaticapps.net.

# Check domain status in Azure (repeat until Validated)
az staticwebapp hostname show \
  --resource-group $RESOURCE_GROUP \
  --name $SWA_NAME \
  --hostname $CUSTOM_DOMAIN \
  --query "status" -o tsv
# Expected: Validated → then Provisioned
```

Test HTTPS:

```bash
curl -s https://app.abhijeetrajput.life
# Expected: your HTML (HTTPS, free cert, no Front Door needed)

curl -I https://app.abhijeetrajput.life
# Look for: strict-transport-security header (HSTS) — SWA adds this automatically
```

---

## Part 4 — Staging Environments (free feature)

SWA creates a preview URL for every pull request — great for reviewing before merging.

```bash
# List all environments (production + all PR previews)
az staticwebapp environment list \
  --resource-group $RESOURCE_GROUP \
  --name $SWA_NAME \
  --query "[].{Name:name, Hostname:hostname, Stage:stage}" \
  -o table

# Each PR gets a URL like:
# https://swa-task03-<hash>-pr-1.azurestaticapps.net
```

> Preview environments are automatically deleted when the PR is closed.
> No cost on Free plan for staging environments.

---

## Part 5 — Private Endpoint (lock direct access) 💳 Standard plan

> ⛔ Requires SWA Standard plan (~$9/month).
> On Free plan, the private endpoint option is visible in portal but greyed out.

### Step 1 — Upgrade to Standard plan

```bash
az staticwebapp update \
  --resource-group $RESOURCE_GROUP \
  --name $SWA_NAME \
  --sku Standard
```

### Step 2 — Create subnet for private endpoint

```bash
VNET_NAME="vnet-task01"

az network vnet subnet create \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name subnet-privateep \
  --address-prefixes 10.10.3.0/24

# Enable network policy so NSG rules can apply to private endpoint traffic
az network vnet subnet update \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name subnet-privateep \
  --private-endpoint-network-policies Enabled
```

> **No subnet delegation needed** — private endpoints don't require delegation.
> **No route table** — private endpoints are inbound-only, no outbound routing needed.

### Step 3 — Get SWA resource ID

```bash
SWA_ID=$(az staticwebapp show \
  --resource-group $RESOURCE_GROUP \
  --name $SWA_NAME \
  --query id -o tsv)

echo "SWA Resource ID: $SWA_ID"
```

### Step 4 — Create private endpoint

```bash
az network private-endpoint create \
  --resource-group $RESOURCE_GROUP \
  --name pe-swa-task03 \
  --location $LOCATION \
  --vnet-name $VNET_NAME \
  --subnet subnet-privateep \
  --private-connection-resource-id $SWA_ID \
  --group-id staticSites \
  --connection-name pe-swa-conn
```

Get the private IP assigned:

```bash
az network private-endpoint show \
  --resource-group $RESOURCE_GROUP \
  --name pe-swa-task03 \
  --query "customDnsConfigs[].{FQDN:fqdn, IP:ipAddresses[0]}" \
  -o table
# Example: swa-task03.azurestaticapps.net  →  10.10.3.5
```

### Step 5 — Create Private DNS Zone

```bash
# Create the zone
az network private-dns zone create \
  --resource-group $RESOURCE_GROUP \
  --name "privatelink.azurestaticapps.net"

# Link it to VNet
az network private-dns link vnet create \
  --resource-group $RESOURCE_GROUP \
  --zone-name "privatelink.azurestaticapps.net" \
  --name link-vnet-swa \
  --virtual-network $VNET_NAME \
  --registration-enabled false

# Add A record (use private IP from Step 4)
az network private-dns record-set a add-record \
  --resource-group $RESOURCE_GROUP \
  --zone-name "privatelink.azurestaticapps.net" \
  --record-set-name $SWA_NAME \
  --ipv4-address 10.10.3.5
```

### Step 6 — Disable public access

```bash
az staticwebapp update \
  --resource-group $RESOURCE_GROUP \
  --name $SWA_NAME \
  --public-network-access Disabled
```

Verify:

```bash
# From internet — should be BLOCKED
curl --connect-timeout 5 https://swa-task03.azurestaticapps.net
# Expected: 403 Forbidden

# From inside VNet (e.g. a VM in subnet-backend) — should WORK
# DNS resolves to 10.10.3.5 (private endpoint) instead of public IP
curl https://swa-task03.azurestaticapps.net
# Expected: your app HTML
```

---

## Part 6 — Front Door Premium with Private Link 👑 Premium only

> ⛔ Requires Front Door Premium tier (~$330/month).
> This allows Front Door → SWA via Private Link (so SWA stays locked, but internet users
> can still reach it via Front Door's public endpoint).

```
INTERNET → Front Door Premium (public) → Private Link → SWA (private access disabled)
                                                          ↑
                                    No direct internet path exists
```

### Step 1 — Create Front Door Premium profile

```bash
az afd profile create \
  --resource-group $RESOURCE_GROUP \
  --profile-name afd-task03-premium \
  --sku Premium_AzureFrontDoor
```

### Step 2 — Create endpoint

```bash
az afd endpoint create \
  --resource-group $RESOURCE_GROUP \
  --profile-name afd-task03-premium \
  --endpoint-name endpoint-swa \
  --enabled-state Enabled
```

### Step 3 — Create origin group + origin with Private Link

```bash
az afd origin-group create \
  --resource-group $RESOURCE_GROUP \
  --profile-name afd-task03-premium \
  --origin-group-name og-swa \
  --probe-request-type HEAD \
  --probe-protocol Https \
  --probe-interval-in-seconds 100 \
  --probe-path "/" \
  --sample-size 4 \
  --successful-samples-required 3 \
  --additional-latency-in-milliseconds 50

az afd origin create \
  --resource-group $RESOURCE_GROUP \
  --profile-name afd-task03-premium \
  --origin-group-name og-swa \
  --origin-name swa-origin \
  --host-name $SWA_HOSTNAME \
  --origin-host-header $SWA_HOSTNAME \
  --https-port 443 \
  --priority 1 \
  --weight 1000 \
  --enabled-state Enabled \
  --enable-private-link true \
  --private-link-location $LOCATION \
  --private-link-resource $SWA_ID \
  --private-link-sub-resource-type sites \
  --private-link-request-message "Front Door access"
```

### Step 4 — Approve the Private Endpoint connection

Front Door creates a pending private endpoint — you must approve it from the SWA side:

```bash
# List pending connections
az network private-endpoint-connection list \
  --resource-group $RESOURCE_GROUP \
  --name $SWA_NAME \
  --type Microsoft.Web/staticSites \
  --query "[?properties.privateLinkServiceConnectionState.status=='Pending'].{Name:name, Status:properties.privateLinkServiceConnectionState.status}" \
  -o table

# Approve it (replace <connection-name> with name from above)
az network private-endpoint-connection approve \
  --resource-group $RESOURCE_GROUP \
  --name <connection-name> \
  --resource-name $SWA_NAME \
  --type Microsoft.Web/staticSites \
  --description "Approved"
```

### Step 5 — Create route + custom domain

```bash
az afd route create \
  --resource-group $RESOURCE_GROUP \
  --profile-name afd-task03-premium \
  --endpoint-name endpoint-swa \
  --route-name route-swa \
  --origin-group og-swa \
  --supported-protocols Http Https \
  --https-redirect Enabled \
  --forwarding-protocol HttpsOnly \
  --patterns-to-match "/*" \
  --link-to-default-domain Enabled

# Add custom domain (same DNS steps as storage — CNAME + TXT validation)
az afd custom-domain create \
  --resource-group $RESOURCE_GROUP \
  --profile-name afd-task03-premium \
  --custom-domain-name app-abhijeetrajput \
  --host-name $CUSTOM_DOMAIN \
  --minimum-tls-version TLS12 \
  --certificate-type ManagedCertificate
```

Update DNS:

| Type | Name | Value | TTL |
|------|------|-------|-----|
| CNAME | `app` | `endpoint-swa.z01.azurefd.net` | 60 |
| TXT | `_dnsauth.app` | `<validationToken from afd custom-domain show>` | 60 |

### Step 6 — Test

```bash
# Via Front Door → should work (Private Link path)
curl -s https://app.abhijeetrajput.life
# Expected: your app HTML

# Direct to SWA → should be blocked
curl --connect-timeout 5 https://swa-task03.azurestaticapps.net
# Expected: 403 Forbidden
```

---

## Comparison — Storage Static Site vs SWA (for this lab)

| | `01-storage-account-static-website.md` | `02-swa-static-webapp.md` (this file) |
|-|----------------------------------------|---------------------------------------|
| Hosting | Azure Blob Storage `$web` | Azure Static Web Apps |
| Deploy method | `az storage blob upload` | GitHub Actions or SWA CLI |
| Custom domain HTTPS | Needs Front Door (paid) | ✅ Built-in, free |
| React/Vue support | ❌ Must pre-build yourself | ✅ SWA builds for you |
| API backend | ❌ No | ✅ Azure Functions |
| Staging envs | ❌ No | ✅ Per-PR previews |
| Private access lock | ❌ Not supported | ✅ Standard plan |
| Cost (basic) | ~$0.01/GB/month | Free tier available |
| Best for | Simple HTML/CSS/JS, full CDN control | Modern JS frameworks, CI/CD |

---

## Cleanup

```bash
# Remove custom domain first
az staticwebapp hostname delete \
  --resource-group $RESOURCE_GROUP \
  --name $SWA_NAME \
  --hostname $CUSTOM_DOMAIN \
  --yes

# Delete private endpoint (if created)
az network private-endpoint delete \
  --resource-group $RESOURCE_GROUP \
  --name pe-swa-task03

# Delete private DNS zone
az network private-dns record-set a remove-record \
  --resource-group $RESOURCE_GROUP \
  --zone-name "privatelink.azurestaticapps.net" \
  --record-set-name $SWA_NAME \
  --ipv4-address 10.10.3.5

az network private-dns link vnet delete \
  --resource-group $RESOURCE_GROUP \
  --zone-name "privatelink.azurestaticapps.net" \
  --name link-vnet-swa --yes

az network private-dns zone delete \
  --resource-group $RESOURCE_GROUP \
  --name "privatelink.azurestaticapps.net" --yes

# Delete Front Door (if created)
az afd profile delete \
  --resource-group $RESOURCE_GROUP \
  --profile-name afd-task03-premium \
  --yes

# Delete SWA
az staticwebapp delete \
  --resource-group $RESOURCE_GROUP \
  --name $SWA_NAME \
  --yes
```
