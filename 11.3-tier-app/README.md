# Project 2 — 3-Tier Architecture on Azure

## Status: ⏳ Pending (complete after Day 9)

---

## Architecture

```
Internet
    │
    ▼
Application Gateway (WAF v2)        ← Layer 7 LB + WAF
Public IP: x.x.x.x
    │
    ├── /api/*  ──────────────────► Backend API VM (10.0.2.4)
    │                                  │
    │                                  │ Managed Identity
    │                                  ▼
    │                              PostgreSQL (10.0.3.4) ← db-subnet, no public IP
    │                              Key Vault             ← reads DB password
    │
    └── /web/*  ──────────────────► Frontend VM (10.0.2.5)
                                       │
                                       │ Managed Identity
                                       ▼
                                   Blob Storage ← static assets

VNet: 10.0.0.0/16
  ├── appgw-subnet   10.0.4.0/26  ← App Gateway ONLY
  ├── private-subnet 10.0.2.0/24  ← Frontend + Backend VMs
  └── db-subnet      10.0.3.0/24  ← PostgreSQL (VNet integrated)

Supporting:
  Key Vault      ← DB password stored here, read via Managed Identity
  Log Analytics  ← All logs from all resources
  Private DNS    ← db.mylab.internal → 10.0.3.x
```

## What You Learn From This
- 3-tier design with proper network isolation
- Application Gateway URL routing (/api vs /web)
- Private database — zero public exposure
- Secret management with Key Vault + Managed Identity
- Private DNS for internal hostname resolution
- Centralized logging

---

## Project Structure

```
3-tier-app/
  ├── README.md             ← this file
  ├── frontend/
  │     ├── app.py          ← Flask frontend (serves HTML, calls backend API)
  │     ├── requirements.txt
  │     └── templates/
  │           └── index.html
  ├── backend/
  │     ├── app.py          ← Flask API (reads/writes PostgreSQL)
  │     └── requirements.txt
  ├── scripts/
  │     ├── setup-frontend.sh
  │     └── setup-backend.sh
  └── terraform/
        ├── main.tf         ← full infrastructure
        ├── variables.tf
        └── outputs.tf
```

---

## Task Checklist

### Step 1 — Network (Portal)
- [ ] VNet (10.0.0.0/16)
- [ ] appgw-subnet (10.0.4.0/26) — App Gateway only
- [ ] private-subnet (10.0.2.0/24) — Private subnet: ENABLED
- [ ] db-subnet (10.0.3.0/24) — Private subnet: ENABLED
- [ ] nsg-private: allow port 5000 from appgw-subnet
- [ ] nsg-private: allow port 5001 from private-subnet (frontend → backend)
- [ ] nsg-db: allow port 5432 from private-subnet only

### Step 2 — Database (Portal)
- [ ] Create PostgreSQL Flexible Server in db-subnet (VNet integrated)
- [ ] Create database `appdb`, table `items`
- [ ] Private DNS Zone configured automatically

### Step 3 — Key Vault (Portal)
- [ ] Create Key Vault
- [ ] Store secret: `db-password`
- [ ] Store secret: `db-host` (PostgreSQL hostname)

### Step 4 — VMs (Portal)
- [ ] Create frontend-vm in private-subnet (no public IP)
- [ ] Create backend-vm in private-subnet (no public IP)
- [ ] Enable Managed Identity on both VMs
- [ ] Assign Key Vault Secrets User role to both VM identities

### Step 5 — App Gateway (Portal)
- [ ] Create Application Gateway WAF v2 in appgw-subnet
- [ ] Backend pool: frontend-pool (frontend-vm)
- [ ] Backend pool: api-pool (backend-vm)
- [ ] Listener: port 80
- [ ] Routing rule: /api/* → api-pool, default → frontend-pool

### Step 6 — Deploy Apps (via jump box)
- [ ] Create jump-box VM in a public subnet (just for access)
- [ ] SSH jump-box → SSH frontend-vm → run setup-frontend.sh
- [ ] SSH jump-box → SSH backend-vm → run setup-backend.sh

### Step 7 — Verify
- [ ] curl http://<AppGW_IP>/ → frontend page
- [ ] curl http://<AppGW_IP>/api/items → JSON from PostgreSQL
- [ ] Check Key Vault access logs — VM identity accessed secret
- [ ] Try curl to PostgreSQL from laptop → BLOCKED
