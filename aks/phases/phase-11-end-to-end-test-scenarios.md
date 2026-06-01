# Phase 11 — End-to-End Test Scenarios

> **Lab:** APIM 3 — Public APIM → Private AGW → AKS (httpbin)
> **Source:** [readme.md](../readme.md) → Step 7 (test scenarios)

---

## Overview

6 scenarios verify the full chain: `Client → APIM → AGW → ILB → httpbin pod`

```
curl → APIM (20.193.x.x) → AGW (10.0.3.4) → ILB (10.0.1.50) → httpbin pod → 200
```

---

## Get a JWT token first

```bash
SECRET="<your-app-client-secret>"
TENANT_ID=$(az account show --query tenantId -o tsv)
APP_ID=$(az ad app list --display-name "orders-api" --query "[0].appId" -o tsv)

TOKEN=$(curl -s -X POST \
  "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token" \
  -d "grant_type=client_credentials" \
  -d "client_id=$APP_ID" \
  -d "client_secret=$SECRET" \
  -d "scope=api://$APP_ID/.default" \
  | jq -r .access_token)

echo "Token: ${TOKEN:0:50}..."
```

## Get APIM subscription key

```bash
SUB_KEY=$(az apim subscription list \
  --resource-group $RESOURCE_GROUP \
  --service-name $APIM_NAME \
  --query "[0].primaryKey" -o tsv)
echo "Sub key: $SUB_KEY"
```

---

## Scenario 1 — No JWT → 401

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  https://api.abhijeetrajput.life/orders/get
# Expected: HTTP 401 ✅
# Handled by: APIM validate-jwt policy
```

---

## Scenario 2 — Bad JWT → 401

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  -H "Authorization: Bearer fake.token" \
  -H "Ocp-Apim-Subscription-Key: $SUB_KEY" \
  https://api.abhijeetrajput.life/orders/get
# Expected: HTTP 401 ✅
# Handled by: APIM validate-jwt policy (signature validation fails)
```

---

## Scenario 3 — Happy path → 200

```bash
curl -s -w "\nHTTP %{http_code}\n" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Ocp-Apim-Subscription-Key: $SUB_KEY" \
  https://api.abhijeetrajput.life/orders/get
# Expected: HTTP 200 + httpbin JSON ✅
# X-Appgw-Trace-Id in response headers → confirms traffic passed through AGW
# origin field → 10.0.2.x → confirms APIM forwarded via its private IP
```

---

## Scenario 4 — Authorization header stripped at pod

```bash
curl -s \
  -H "Authorization: Bearer $TOKEN" \
  -H "Ocp-Apim-Subscription-Key: $SUB_KEY" \
  https://api.abhijeetrajput.life/orders/headers | jq .headers
# Expected: no "Authorization" key in output ✅
# Ocp-Apim-Subscription-Key will still be present — that is correct behaviour
# Handled by: APIM <set-header name="Authorization" exists-action="delete" />
```

---

## Scenario 5 — Rate limit → 429

```bash
for i in $(seq 1 210); do
  curl -s -o /dev/null -w "Request $i: %{http_code}\n" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Ocp-Apim-Subscription-Key: $SUB_KEY" \
    https://api.abhijeetrajput.life/orders/get
done
# Requests 1–200:  HTTP 200
# Requests 201+:   HTTP 429 ✅
# Handled by: APIM rate-limit-by-key (200 calls/60s per subscription)
# Note: refresh $TOKEN if the loop takes more than ~1 hour
```

---

## Scenario 6 — Private AGW unreachable from internet

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" --connect-timeout 5 \
  http://10.0.3.4/orders/get
# Expected: timeout (HTTP 000) ✅
# Confirmed by: NSG on snet-agw blocks all internet inbound to private IP
```

---

## All scenarios at a glance

| # | Scenario | Handled by | Expected | Result |
|---|---|---|---|---|
| 1 | No JWT | APIM validate-jwt | 401 | ⬜ |
| 2 | Bad JWT | APIM validate-jwt | 401 | ⬜ |
| 3 | Happy path | Full chain | 200 | ⬜ |
| 4 | Auth header stripped | APIM set-header delete | No Authorization at pod | ⬜ |
| 5 | Rate limit | APIM rate-limit-by-key | 429 after 200 calls | ⬜ |
| 6 | AGW unreachable from internet | NSG on snet-agw | Timeout | ⬜ |

---

## Traffic summary

| Hop | Protocol | From | To | Port |
|---|---|---|---|---|
| Client → APIM | HTTPS | Internet | APIM public IP | 443 |
| APIM → AGW | HTTP | `10.0.2.x` | `10.0.3.4` | 80 |
| AGW → ILB | HTTP | `10.0.3.x` | `10.0.1.50` | 80 |
| ILB → pod | HTTP | ILB | Pod | 80 |

---

## Phase 11 complete? ⬜ All 6 scenarios produce the expected result.

---

## Tasks covered by this lab

| Task | What it covers | Where in this lab |
|---|---|---|
| Task 04 — AGIC + SSL | SSL/TLS Let's Encrypt, custom domain | Phase 05 (certbot, PFX, APIM custom domain) |
| Task 04 — AGIC concept | Why AGW doesn't need AGIC here | Phase 06 concept note |
| Task 05 — Entra ID RBAC | AKS cluster-level user/group/namespace access | Phase 04 |
| Task 05 — Entra ID JWT | API-level token validation | Phase 07 (validate-jwt) |
| Task 06 — PostgreSQL Private Link | Private DB, VNet integration, DNS, K8s Secret | Phase 08 |
| Task 09 Phase 2 — OpenVPN | VPN VM setup, IP forwarding, NSG, .ovpn | Phase 03 |
| Task 09 Phase 7 — Workload Identity | Managed Identity, OIDC, federated credential, KV | Phase 09 |
| Task 09 Phase 8 — Blob Storage | Storage account, pod reads/writes via WI | Phase 10 |
