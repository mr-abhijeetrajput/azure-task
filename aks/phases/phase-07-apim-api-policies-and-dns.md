# Phase 07 — APIM API + Policies + DNS

> **Lab:** APIM 3 — Public APIM → Private AGW → AKS (httpbin)
> **Source:** [readme.md](../readme.md) → Step 5, Step 6, Step 7

---

## Overview

1. Create the `Orders API` in APIM with backend = private AGW `10.0.3.4`
2. Add 4 operations (`/get`, `/post`, `/headers`, `/ip`)
3. Apply inbound policies: JWT validation, rate limiting, header strip
4. Point Hostinger DNS A record to APIM public IP

---

## 7.1 Create the Orders API

**Portal:** `apim-myapp-pub` → `APIs` → `+ Add API` → `HTTP`

| Field | Value |
|---|---|
| Display name | `Orders API` |
| Name | `orders-api` |
| Description | `httpbin-based orders service via private AGW` |
| Web service URL | `http://10.0.3.4` |
| URL scheme | `HTTPS` |
| API URL suffix | `orders` |
| Gateways | `Managed` ✔️ |
| Subscription required | ✔️ on |

> **Base URL** confirms as `https://api.abhijeetrajput.life/orders`.
> **URL scheme `HTTPS` not `HTTP(S)`** — clients always hit APIM over HTTPS; `HTTP(S)` is too permissive.

Click **Create**.

---

## 7.2 Add operations

**Portal:** `Orders API` → `Design` → `+ Add operation` (save after each)

| Display name | Method | URL path |
|---|---|---|
| `Get` | `GET` | `/get` |
| `Post` | `POST` | `/post` |
| `Headers` | `GET` | `/headers` |
| `IP` | `GET` | `/ip` |

Full URLs after adding:

| Operation | Full URL |
|---|---|
| Get | `https://api.abhijeetrajput.life/orders/get` |
| Post | `https://api.abhijeetrajput.life/orders/post` |
| Headers | `https://api.abhijeetrajput.life/orders/headers` |
| IP | `https://api.abhijeetrajput.life/orders/ip` |

---

## 7.3 Apply inbound policies

Get tenant and app IDs first:

```bash
TENANT_ID=$(az account show --query tenantId -o tsv)
APP_ID=$(az ad app list --display-name "orders-api" --query "[0].appId" -o tsv)
echo "Tenant : $TENANT_ID"
echo "App ID : $APP_ID"
```

**Portal:** `Orders API` → `Design` → `All operations` → `</>` (Inbound processing)

Paste the full block below — replace `{tenant-id}` and `{app-id}`:

```xml
<policies>
  <inbound>
    <base />
    <validate-jwt header-name="Authorization"
                  failed-validation-httpcode="401"
                  failed-validation-error-message="Unauthorized">
      <openid-config url="https://login.microsoftonline.com/{tenant-id}/.well-known/openid-configuration" />
      <required-claims>
        <claim name="aud">
          <value>api://orders</value>
        </claim>
      </required-claims>
    </validate-jwt>
    <rate-limit-by-key
      calls="200"
      renewal-period="60"
      counter-key="@(context.Subscription.Id)"
      remaining-calls-header-name="X-RateLimit-Remaining"
      retry-after-header-name="Retry-After" />
    <set-header name="X-Forwarded-For" exists-action="override">
      <value>@(context.Request.IpAddress)</value>
    </set-header>
    <set-header name="Authorization" exists-action="delete" />
    <set-backend-service base-url="http://10.0.3.4" />
  </inbound>
  <backend>
    <base />
  </backend>
  <outbound>
    <base />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>
```

Click **Save**. Verify no red error banner — policy tiles should appear under Inbound processing.

> ⚠️ Replace `{tenant-id}` with `$TENANT_ID` and `{app-id}` with `$APP_ID` before saving.
> APIM fetches the OpenID config URL at save time — placeholders cause an immediate fetch error.
>
> ⚠️ If `api://orders` is blocked by tenant policy, use `api://{app-id}` as the audience value.
> Ensure a service principal exists: `az ad sp create --id $APP_ID`
>
> ⚠️ Use the **full `<policies>` block editor only** (Inbound processing `</>`).
> The scoped editors (Outbound box, Backend box) reject `<base />` + any policy together.

---

## 7.4 Point DNS to APIM public IP

In Hostinger hPanel → Domains → `abhijeetrajput.life` → DNS/Nameservers:

| Type | Name | Points to | TTL |
|---|---|---|---|
| `A` | `api` | `<APIM_PUBLIC_IP>` | `300` |

```bash
# Get APIM public IP
az apim show \
  --resource-group $RESOURCE_GROUP \
  --name $APIM_NAME \
  --query "publicIpAddresses[0]" -o tsv

# Verify DNS propagation
dig api.abhijeetrajput.life +short
# Must return APIM public IP (NOT AGW IP — AGW has no public DNS)
```

### Who resolves what

| Who is asking | Resolves to |
|---|---|
| Internet / laptop | APIM **public** IP (Hostinger) |
| APIM → AGW | `http://10.0.3.4` (policy `set-backend-service`) |
| AGW → AKS | `http://10.0.1.50` |

---

## Phase 07 complete? ⬜ API created with policies, DNS resolves to APIM public IP.
