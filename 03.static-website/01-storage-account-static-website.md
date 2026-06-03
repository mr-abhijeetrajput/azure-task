# Static Website Hosting — Azure Storage Account + Custom DNS

> **Goal:** Host a static website (HTML/CSS/JS) on Azure Blob Storage, serve it on a
> custom domain (`www.abhijeetrajput.life`), and optionally front it with Azure Front Door
> for CDN caching and global performance.
>
> **Cost:**
> - Storage Account + Static Website → ✅ FREE (LRS, <5GB)
> - Custom Domain (CNAME/A record only) → ✅ FREE
> - Azure Front Door Standard → 💳 ~$35/month
>
> **Prerequisites:** Run `00-foundation-setup.md` first (resource group, VNet already exist).

---

## What you will build

```
OPTION A (Free):

  User Browser
       │  https://www.abhijeetrajput.life
       │  CNAME → sttask03lab001.z13.web.core.windows.net
       ▼
  Azure Blob Storage — Static Website
  $web container → index.html, 404.html


OPTION B (Paid — adds Front Door):

  User Browser
       │  https://www.abhijeetrajput.life
       │  CNAME → endpoint-task03.z01.azurefd.net
       ▼
  Azure Front Door Standard
  CDN cache + HTTPS redirect + compression
       │
       ▼
  Azure Blob Storage — Static Website
  (origin: sttask03lab001.z13.web.core.windows.net)
```

---

## Environment variables

```bash
RESOURCE_GROUP="rg-task01"
LOCATION="eastus"          # static websites not available in all regions — eastus is safe
STORAGE_NAME="sttask03lab001"   # must be globally unique, 3-24 chars, lowercase only
CUSTOM_DOMAIN="www.abhijeetrajput.life"
```

---

## Part 1 — Create Storage Account

```bash
az storage account create \
  --resource-group $RESOURCE_GROUP \
  --name $STORAGE_NAME \
  --location $LOCATION \
  --sku Standard_LRS \
  --kind StorageV2 \
  --access-tier Hot \
  --allow-blob-public-access true \
  --min-tls-version TLS1_2 \
  --https-only true
```

> **Why `--allow-blob-public-access true`?**
> The `$web` container that hosts static websites needs anonymous read access.
> Without this flag, enabling anonymous access on the container fails.
> This is safe for static sites — it only allows reading the HTML/CSS/JS files.

Verify:

```bash
az storage account show \
  --resource-group $RESOURCE_GROUP \
  --name $STORAGE_NAME \
  --query "{Name:name, Location:primaryLocation, TLS:minimumTlsVersion, PublicAccess:allowBlobPublicAccess}" \
  -o table
```

---

## Part 2 — Enable Static Website

```bash
az storage blob service-properties update \
  --account-name $STORAGE_NAME \
  --static-website \
  --index-document index.html \
  --404-document 404.html
```

Get the static website endpoint (this is your origin URL):

```bash
STATIC_ENDPOINT=$(az storage account show \
  --resource-group $RESOURCE_GROUP \
  --name $STORAGE_NAME \
  --query "primaryEndpoints.web" -o tsv)

echo "Static website endpoint: $STATIC_ENDPOINT"
# Example: https://sttask03lab001.z13.web.core.windows.net/
```

> Azure automatically creates a `$web` container when static website is enabled.
> All your HTML/CSS/JS files go into this container.

---

## Part 3 — Create and Upload Website Files

### Create sample HTML files locally

```bash
mkdir -p ~/static-site

cat << 'EOF' > ~/static-site/index.html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>My Azure Static Site</title>
  <style>
    body { font-family: sans-serif; max-width: 800px; margin: 80px auto; padding: 0 20px; }
    h1 { color: #0078d4; }
    .badge { background: #e8f5e9; color: #2e7d32; padding: 4px 12px; border-radius: 4px; font-size: 14px; }
  </style>
</head>
<body>
  <h1>Hello from Azure Storage Static Site 🚀</h1>
  <p><span class="badge">Hosted on Azure Blob Storage</span></p>
  <p>Domain: <strong>www.abhijeetrajput.life</strong></p>
  <p>This page is served directly from the $web container.</p>
</body>
</html>
EOF

cat << 'EOF' > ~/static-site/404.html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>404 - Page Not Found</title>
  <style>
    body { font-family: sans-serif; text-align: center; padding: 80px; }
    h1 { color: #d32f2f; }
  </style>
</head>
<body>
  <h1>404</h1>
  <p>Page not found.</p>
  <a href="/">← Back to Home</a>
</body>
</html>
EOF
```

### Upload to $web container

```bash
# Get storage account key
STORAGE_KEY=$(az storage account keys list \
  --resource-group $RESOURCE_GROUP \
  --account-name $STORAGE_NAME \
  --query "[0].value" -o tsv)

# Upload index.html
az storage blob upload \
  --account-name $STORAGE_NAME \
  --account-key $STORAGE_KEY \
  --container-name '$web' \
  --name index.html \
  --file ~/static-site/index.html \
  --content-type "text/html" \
  --overwrite

# Upload 404.html
az storage blob upload \
  --account-name $STORAGE_NAME \
  --account-key $STORAGE_KEY \
  --container-name '$web' \
  --name 404.html \
  --file ~/static-site/404.html \
  --content-type "text/html" \
  --overwrite

# Verify files are uploaded
az storage blob list \
  --account-name $STORAGE_NAME \
  --account-key $STORAGE_KEY \
  --container-name '$web' \
  --query "[].{Name:name, Size:properties.contentLength, ContentType:properties.contentSettings.contentType}" \
  -o table
```

Test the static endpoint directly:

```bash
curl -s $STATIC_ENDPOINT
# Expected: your index.html content

curl -s "${STATIC_ENDPOINT}nonexistent.html"
# Expected: your 404.html content
```

---

## Part 4 — Custom Domain (CNAME method)

Azure Storage static websites support custom domains via CNAME.

> **Limitation:** Azure Blob Storage natively does NOT support HTTPS on custom domains.
> For HTTPS on your custom domain, you need Front Door or CDN (Part 5).
> HTTP-only custom domain works for free (steps below).

### Step 1 — Add CNAME in your DNS provider

| Type | Name | Value | TTL |
|------|------|-------|-----|
| CNAME | `www` | `sttask03lab001.z13.web.core.windows.net` | 60 |

> Replace `sttask03lab001.z13.web.core.windows.net` with your actual static endpoint
> (without `https://` and without trailing `/`).

Verify DNS propagation before next step:

```bash
# Wait 2-5 minutes, then verify
dig CNAME www.abhijeetrajput.life +short
# Expected: sttask03lab001.z13.web.core.windows.net.

# Or on Windows
nslookup www.abhijeetrajput.life
```

### Step 2 — Map custom domain to storage account

```bash
az storage account custom-domain set \
  --resource-group $RESOURCE_GROUP \
  --name $STORAGE_NAME \
  --custom-domain $CUSTOM_DOMAIN \
  --use-subdomain false
```

> `--use-subdomain false` = direct CNAME method (simpler, works for most cases).
> `--use-subdomain true` = asverify method (used when you can't have downtime —
> verify ownership before switching traffic).

Verify:

```bash
az storage account show \
  --resource-group $RESOURCE_GROUP \
  --name $STORAGE_NAME \
  --query "customDomain" \
  -o table
# Expected: name=www.abhijeetrajput.life  useSubDomainName=false
```

Test:

```bash
curl http://www.abhijeetrajput.life
# Expected: your index.html (HTTP only — no HTTPS yet without Front Door)
```

---

## Part 5 — Azure Front Door (HTTPS + CDN) 💳 Paid

> ⛔ Azure Front Door Standard = ~$35/month.
> Skip this if on free tier — your site works on HTTP via CNAME above.
> Come back when you have a paid subscription.

### Why Front Door for a static site?

| Without Front Door | With Front Door |
|--------------------|----------------|
| HTTP only on custom domain | HTTPS on custom domain |
| Traffic hits East US datacenter always | Global CDN — cached at nearest PoP |
| No DDoS protection | DDoS + WAF (Standard tier: custom rules) |
| No HTTP→HTTPS redirect | Automatic redirect |
| No compression | Gzip/Brotli enabled |

### Step 1 — Register Microsoft.Cdn provider (one-time)

```bash
az provider register --namespace Microsoft.Cdn

# Wait for registration (check status)
az provider show --namespace Microsoft.Cdn --query "registrationState" -o tsv
# Expected: Registered
```

### Step 2 — Create Front Door profile

```bash
az afd profile create \
  --resource-group $RESOURCE_GROUP \
  --profile-name afd-task03 \
  --sku Standard_AzureFrontDoor
```

### Step 3 — Create endpoint

```bash
az afd endpoint create \
  --resource-group $RESOURCE_GROUP \
  --profile-name afd-task03 \
  --endpoint-name endpoint-task03 \
  --enabled-state Enabled

AFD_ENDPOINT=$(az afd endpoint show \
  --resource-group $RESOURCE_GROUP \
  --profile-name afd-task03 \
  --endpoint-name endpoint-task03 \
  --query hostName -o tsv)

echo "Front Door endpoint: $AFD_ENDPOINT"
# Example: endpoint-task03.z01.azurefd.net
```

### Step 4 — Create origin group

```bash
az afd origin-group create \
  --resource-group $RESOURCE_GROUP \
  --profile-name afd-task03 \
  --origin-group-name og-storage \
  --probe-request-type HEAD \
  --probe-protocol Https \
  --probe-interval-in-seconds 100 \
  --probe-path "/" \
  --sample-size 4 \
  --successful-samples-required 3 \
  --additional-latency-in-milliseconds 50
```

### Step 5 — Add storage as origin

```bash
# Get the static website hostname (without https:// and without trailing /)
ORIGIN_HOSTNAME=$(az storage account show \
  --resource-group $RESOURCE_GROUP \
  --name $STORAGE_NAME \
  --query "primaryEndpoints.web" -o tsv | \
  sed 's|https://||' | sed 's|/$||')

echo "Origin hostname: $ORIGIN_HOSTNAME"
# Example: sttask03lab001.z13.web.core.windows.net

az afd origin create \
  --resource-group $RESOURCE_GROUP \
  --profile-name afd-task03 \
  --origin-group-name og-storage \
  --origin-name storage-origin \
  --host-name $ORIGIN_HOSTNAME \
  --origin-host-header $ORIGIN_HOSTNAME \
  --http-port 80 \
  --https-port 443 \
  --priority 1 \
  --weight 1000 \
  --enabled-state Enabled
```

### Step 6 — Create route

```bash
az afd route create \
  --resource-group $RESOURCE_GROUP \
  --profile-name afd-task03 \
  --endpoint-name endpoint-task03 \
  --route-name route-storage \
  --origin-group og-storage \
  --supported-protocols Http Https \
  --https-redirect Enabled \
  --forwarding-protocol HttpsOnly \
  --patterns-to-match "/*" \
  --enable-compression true \
  --query-string-caching-behavior IgnoreQueryString \
  --link-to-default-domain Enabled
```

### Step 7 — Add custom domain to Front Door (HTTPS)

```bash
# Create the custom domain in Front Door
az afd custom-domain create \
  --resource-group $RESOURCE_GROUP \
  --profile-name afd-task03 \
  --custom-domain-name www-abhijeetrajput \
  --host-name $CUSTOM_DOMAIN \
  --minimum-tls-version TLS12 \
  --certificate-type ManagedCertificate

# Get the validation token Azure needs
az afd custom-domain show \
  --resource-group $RESOURCE_GROUP \
  --profile-name afd-task03 \
  --custom-domain-name www-abhijeetrajput \
  --query "{HostName:hostName, ValidationToken:validationProperties.validationToken, DNSState:domainValidationState}" \
  -o table
```

### Step 8 — Update DNS for Front Door custom domain

Remove the old CNAME (pointing to storage) and add:

| Type | Name | Value | TTL |
|------|------|-------|-----|
| CNAME | `www` | `endpoint-task03.z01.azurefd.net` | 60 |
| TXT | `_dnsauth.www` | `<validationToken from above>` | 60 |

> The TXT record proves to Azure you own the domain — needed for managed SSL cert.
> After adding, wait 5-10 minutes, then check validation:

```bash
az afd custom-domain show \
  --resource-group $RESOURCE_GROUP \
  --profile-name afd-task03 \
  --custom-domain-name www-abhijeetrajput \
  --query "domainValidationState" -o tsv
# Expected: Approved (after DNS propagates)
```

### Step 9 — Associate custom domain with route

```bash
az afd route update \
  --resource-group $RESOURCE_GROUP \
  --profile-name afd-task03 \
  --endpoint-name endpoint-task03 \
  --route-name route-storage \
  --custom-domains www-abhijeetrajput
```

### Step 10 — Test

```bash
# HTTP → should redirect to HTTPS
curl -v http://www.abhijeetrajput.life 2>&1 | grep -E "HTTP|Location"
# Expected: 301 → https://www.abhijeetrajput.life/

# HTTPS → should return your index.html
curl -s https://www.abhijeetrajput.life
# Expected: index.html content

# Check CDN cache headers
curl -I https://www.abhijeetrajput.life
# Look for: X-Cache: TCP_HIT (cache hit) or TCP_MISS (first request)
```

---

## Part 6 — Bulk Upload (multiple files)

For a real site with CSS, JS, images:

```bash
# Upload entire directory to $web container
az storage blob upload-batch \
  --account-name $STORAGE_NAME \
  --account-key $STORAGE_KEY \
  --destination '$web' \
  --source ~/static-site/ \
  --overwrite

# Set correct content-types (browser needs these for CSS/JS)
az storage blob update \
  --account-name $STORAGE_NAME \
  --account-key $STORAGE_KEY \
  --container-name '$web' \
  --name style.css \
  --content-type "text/css"

az storage blob update \
  --account-name $STORAGE_NAME \
  --account-key $STORAGE_KEY \
  --container-name '$web' \
  --name script.js \
  --content-type "application/javascript"
```

---

## Summary

| Feature | How it works |
|---------|-------------|
| Static website hosting | `$web` container + static website enabled on storage account |
| Custom domain (HTTP) | CNAME record → blob static endpoint, then `az storage account custom-domain set` |
| Custom domain (HTTPS) | CNAME → Front Door endpoint + TXT validation record + managed certificate |
| CDN caching | Front Door caches responses at nearest PoP globally |
| HTTP → HTTPS redirect | Front Door route setting: `--https-redirect Enabled` |
| 404 page | Set via `--404-document 404.html` in static website config |

---

## Cleanup

```bash
# Remove custom domain from storage (before deleting)
az storage account custom-domain remove \
  --resource-group $RESOURCE_GROUP \
  --name $STORAGE_NAME

# Delete Front Door (if created)
az afd profile delete \
  --resource-group $RESOURCE_GROUP \
  --profile-name afd-task03 \
  --yes

# Delete storage account
az storage account delete \
  --resource-group $RESOURCE_GROUP \
  --name $STORAGE_NAME \
  --yes
```
