# 3-Tier App — Manual Deployment Guide (Portal)

## Architecture

```
Your Laptop
    │  OpenVPN (UDP 1194)
    ▼
vm-openvpn  ──  public-subnet 10.0.1.0/24   (Public IP)
    │
    │  VPN tunnel (10.8.0.0/24) — your laptop becomes part of the VNet
    ▼
vm-backend  ──  private-subnet 10.0.2.0/24  (Private IP: 10.0.2.5, no public IP)
    │
    ├──► Key Vault  (Managed Identity — no passwords in code)
    │
    └──► PostgreSQL  ──  db-subnet 10.0.3.0/24  (VNet integrated, no public IP)

Internet users
    │  HTTP port 80
    ▼
Application Gateway  ──  appgw-subnet 10.0.4.0/26  (Public IP)
    │
    └──► /api/*  →  vm-backend :5001

Blob Storage  (Static Website)
    └── index.html → fetch() → AppGW Public IP → vm-backend
```

---

## Resource Naming Convention

| Resource | Name |
|---|---|
| Resource Group | `3tier-rg` |
| Virtual Network | `3tier-vnet` |
| Subnet — OpenVPN | `public-subnet` |
| Subnet — Backend VM | `private-subnet` |
| Subnet — PostgreSQL | `db-subnet` |
| Subnet — AppGW | `appgw-subnet` |
| NSG — public | `nsg-public` |
| NSG — private | `nsg-private` |
| VM — OpenVPN | `vm-openvpn` |
| VM — Backend | `vm-backend` |
| PostgreSQL Server | `3tier-pg-<unique>` |
| Key Vault | `3tier-kv-<unique>` |
| Application Gateway | `3tier-appgw` |
| Storage Account | `3tierfrontend<unique>` |

---

## Step 1 — Resource Group

1. Portal → search **Resource groups** → **+ Create**
2. **Subscription** — your subscription
3. **Resource group** → `3tier-rg`
4. **Region** → `Central India`
5. Click **Review + create** → **Create**

---

## Step 2 — Virtual Network + Subnets

### Create VNet

1. Portal → search **Virtual networks** → **+ Create**
2. **Resource group** → `3tier-rg`
3. **Name** → `3tier-vnet`
4. **Region** → `Central India`
5. Click **Next: IP Addresses**
6. **IPv4 address space** → `10.0.0.0/16`
7. Delete the default subnet if present
8. Click **+ Add subnet** — add all four subnets below
9. Click **Review + create** → **Create**

### Add Subnets

| Subnet Name | Address Range | Private Subnet | Delegation | Notes |
|---|---|---|---|---|
| `public-subnet` | `10.0.1.0/24` | ❌ Off | None | OpenVPN VM — needs outbound internet |
| `private-subnet` | `10.0.2.0/24` | ✅ On | None | Backend VM — no direct internet needed |
| `db-subnet` | `10.0.3.0/24` | ✅ On | `Microsoft.DBforPostgreSQL/flexibleServers` | PostgreSQL — fully isolated |
| `appgw-subnet` | `10.0.4.0/26` | ❌ Off | None | AppGW requires outbound internet |

> **Private Subnet toggle** — when adding `private-subnet` and `db-subnet`, scroll down and enable **Private subnet** (labelled "Enable private subnet" in portal). This disables default outbound internet access from those subnets — VMs there can only communicate within the VNet or via explicit routes. Leave it **Off** for `public-subnet` and `appgw-subnet`.

> **For `db-subnet` delegation** — when adding this subnet, also scroll to **Subnet delegation** → select `Microsoft.DBforPostgreSQL/flexibleServers`

---

## Step 3 — Network Security Groups

### NSG for public-subnet (OpenVPN VM)

1. Portal → search **Network security groups** → **+ Create**
2. **Resource group** → `3tier-rg` | **Name** → `nsg-public` | **Region** → `Central India`
3. Click **Review + create** → **Create**
4. Open `nsg-public` → **Inbound security rules** → **+ Add** — add these two rules:

| Rule | Priority | Protocol | Port | Source | Action | Name |
|---|---|---|---|---|---|---|
| OpenVPN | 100 | UDP | 1194 | Your public IP `/32` | Allow | `Allow-OpenVPN` |
| SSH setup | 110 | TCP | 22 | Your public IP `/32` | Allow | `Allow-SSH-Setup` |

> **Finding your public IP:** open `https://ifconfig.me` in browser

5. Attach NSG to subnet:
   - Go to `nsg-public` → **Subnets** → **+ Associate**
   - **Virtual network** → `3tier-vnet` | **Subnet** → `public-subnet` → **OK**

---

### NSG for private-subnet (Backend VM)

1. Portal → **Network security groups** → **+ Create**
2. **Name** → `nsg-private` | same RG + region
3. Open `nsg-private` → **Inbound security rules** → **+ Add** — add these rules:

| Rule | Priority | Protocol | Port | Source | Action | Name |
|---|---|---|---|---|---|---|
| SSH via VPN | 100 | TCP | 22 | `10.8.0.0/24` | Allow | `Allow-SSH-VPN` |
| API from AppGW | 110 | TCP | 5001 | `10.0.4.0/26` | Allow | `Allow-AppGW-API` |
| API from VPN (testing) | 120 | TCP | 5001 | `10.8.0.0/24` | Allow | `Allow-VPN-API` |

> `10.8.0.0/24` is the OpenVPN tunnel subnet — once you connect VPN your laptop gets an IP in this range

4. Attach NSG to subnet:
   - Go to `nsg-private` → **Subnets** → **+ Associate**
   - **Virtual network** → `3tier-vnet` | **Subnet** → `private-subnet` → **OK**

---

## Step 4 — OpenVPN VM

1. Portal → **Virtual machines** → **+ Create** → **Azure virtual machine**
2. Fill in:
   - **Resource group** → `3tier-rg`
   - **Virtual machine name** → `vm-openvpn`
   - **Region** → `Central India`
   - **Image** → `Ubuntu Server 22.04 LTS`
   - **Size** → `Standard_B1s`
   - **Authentication type** → `SSH public key`
   - **Username** → `azureuser`
   - **SSH public key source** → `Use existing public key` → paste contents of `~/.ssh/id_rsa.pub`
3. Click **Next: Disks** → leave defaults
4. Click **Next: Networking**:
   - **Virtual network** → `3tier-vnet`
   - **Subnet** → `public-subnet`
   - **Public IP** → create new → name `openvpn-pip` → SKU `Standard`
   - **NIC network security group** → `None` (NSG already on subnet)
5. Click **Review + create** → **Create**

### Enable IP Forwarding on the NIC

After VM is created:

1. Go to `vm-openvpn` → **Networking** → click the NIC name (`vm-openvpn-nic` or similar)
2. Click **IP configurations** (left menu)
3. At the top — toggle **IP forwarding** → **Enabled** → **Save**

> This is required so the OpenVPN VM can route packets from VPN clients (`10.8.0.0/24`) into the VNet (`10.0.0.0/16`)

---

## Step 5 — Backend VM

1. Portal → **Virtual machines** → **+ Create** → **Azure virtual machine**
2. Fill in:
   - **Resource group** → `3tier-rg`
   - **Virtual machine name** → `vm-backend`
   - **Region** → `Central India`
   - **Image** → `Ubuntu Server 22.04 LTS`
   - **Size** → `Standard_B2s`
   - **Authentication type** → `SSH public key`
   - **Username** → `azureuser`
   - **SSH public key source** → `Use existing public key` → paste `~/.ssh/id_rsa.pub`
3. Click **Next: Disks** → leave defaults
4. Click **Next: Networking**:
   - **Virtual network** → `3tier-vnet`
   - **Subnet** → `private-subnet`
   - **Public IP** → **None**
   - **NIC network security group** → `None` (NSG already on subnet)
5. Click **Next: Management**:
   - **System assigned managed identity** → toggle **On**
6. Click **Review + create** → **Create**

### Note Backend VM Private IP

After creation:
- Go to `vm-backend` → **Overview** → note **Private IP address** (should be `10.0.2.5` if first VM in private-subnet, may vary)

---

## Step 6 — PostgreSQL Flexible Server

1. Portal → search **Azure Database for PostgreSQL flexible servers** → **+ Create**
2. **Flexible server** → **Create**
3. Fill in:
   - **Resource group** → `3tier-rg`
   - **Server name** → `3tier-pg-<unique>` (globally unique)
   - **Region** → `Central India`
   - **PostgreSQL version** → `16`
   - **Workload type** → `Development`
   - **Compute + storage** → click **Configure server** → pick `Burstable B1ms` → **Save**
   - **Admin username** → `pgadmin`
   - **Password** → set a strong password, note it down
4. Click **Next: Networking**
5. **Connectivity method** → `Private access (VNet Integration)`
6. **Virtual network** → `3tier-vnet`
7. **Subnet** → `db-subnet` (should show delegation already set)
8. **Private DNS zone** → `Create new` — Azure auto-fills the name, leave as is
9. Click **Review + create** → **Create**

> Provisioning takes ~5 minutes

### Create the App Database

After server is ready:

1. Go to the PostgreSQL server → **Databases** (left menu) → **+ Add**
2. **Database name** → `appdb` → **Save**

---

## Step 7 — Key Vault

1. Portal → search **Key vaults** → **+ Create**
2. Fill in:
   - **Resource group** → `3tier-rg`
   - **Key vault name** → `3tier-kv-<unique>` (globally unique)
   - **Region** → `Central India`
   - **Pricing tier** → `Standard`
3. Click **Next: Access configuration**:
   - **Permission model** → `Azure role-based access control`
4. Click **Review + create** → **Create**

### Give Yourself Access to Write Secrets

1. Go to `3tier-kv-<unique>` → **Access control (IAM)** → **+ Add** → **Add role assignment**
2. **Role** → search `Key Vault Secrets Officer` → select it → **Next**
3. **Members** → **+ Select members** → search your account name → select → **Review + assign**

### Store Secrets

1. Go to Key Vault → **Secrets** (left menu) → **+ Generate/Import** — add these three:

| Name | Value |
|---|---|
| `db-host` | `<your-pg-server-name>.postgres.database.azure.com` |
| `db-user` | `pgadmin` |
| `db-password` | the password you set in Step 6 |

> For each: **Upload options** → `Manual` | fill Name + Value → **Create**

### Give Backend VM Identity Access to Read Secrets

1. Go to Key Vault → **Access control (IAM)** → **+ Add** → **Add role assignment**
2. **Role** → `Key Vault Secrets User` → **Next**
3. **Members** → **Assign access to** → `Managed identity`
4. Click **+ Select members** → **Managed identity** dropdown → `Virtual machine` → select `vm-backend` → **Select** → **Review + assign**

---

## Step 8 — Application Gateway

1. Portal → search **Application gateways** → **+ Create**
2. **Basics** tab:
   - **Resource group** → `3tier-rg`
   - **Application gateway name** → `3tier-appgw`
   - **Region** → `Central India`
   - **Tier** → `Standard V2`
   - **Enable autoscaling** → `No` | **Instance count** → `1`
   - **Virtual network** → `3tier-vnet`
   - **Subnet** → `appgw-subnet`
3. Click **Next: Frontends**:
   - **Frontend IP address type** → `Public`
   - **Public IP address** → **Add new** → name `appgw-pip` → **OK**
4. Click **Next: Backends**:
   - **+ Add a backend pool**
     - **Name** → `backend-pool`
     - **Add backend without targets** → No
     - **Target type** → `IP address or FQDN`
     - **Target** → `10.0.2.5` (Backend VM private IP)
     - **Add**
5. Click **Next: Configuration** → **+ Add a routing rule**:
   - **Rule name** → `backend-rule`
   - **Priority** → `100`
   - **Listener** tab:
     - **Listener name** → `http-listener`
     - **Frontend IP** → `Public`
     - **Protocol** → `HTTP` | **Port** → `80`
   - **Backend targets** tab:
     - **Target type** → `Backend pool`
     - **Backend target** → `backend-pool`
     - **Backend settings** → **Add new**
       - **Name** → `backend-settings`
       - **Protocol** → `HTTP`
       - **Port** → `5001`
       - **Add**
   - **Add**
6. Click **Next: Tags** → skip → **Review + create** → **Create**

> Provisioning takes ~5–8 minutes

### Note AppGW Public IP

After creation:
- Go to `3tier-appgw` → **Overview** → note **Frontend public IP address**

---

## Step 9 — Blob Storage (Static Frontend)

### Create Storage Account

1. Portal → search **Storage accounts** → **+ Create**
2. Fill in:
   - **Resource group** → `3tier-rg`
   - **Storage account name** → `3tierfrontend<unique>` (lowercase, no hyphens, globally unique)
   - **Region** → `Central India`
   - **Performance** → `Standard`
   - **Redundancy** → `LRS`
3. Click **Review** → **Create**

### Enable Static Website

1. Go to your storage account → **Static website** (left menu, under Data management)
2. Toggle **Static website** → **Enabled**
3. **Index document name** → `index.html`
4. Click **Save**
5. Note the **Primary endpoint** URL (e.g. `https://3tierfrontend<unique>.z30.web.core.windows.net/`)

### Upload index.html

Before uploading, edit `index.html` to put in the real AppGW IP:

1. Open `frontend/templates/index.html` in any text editor
2. Find the line: `const BACKEND_URL = "http://APPGW_PUBLIC_IP";`
3. Replace `APPGW_PUBLIC_IP` with the AppGW public IP from Step 8
4. Save the file

Now upload:

1. Go to storage account → **Containers** (left menu) → click the `$web` container
2. Click **Upload** → **Browse for files** → select the edited `index.html`
3. Expand **Advanced** → **Content type** → type `text/html`
4. Click **Upload**

Open the static site URL in browser — it will show the page but items won't load yet (backend not set up yet).

---

## Step 10 — Install OpenVPN on vm-openvpn

Source: https://github.com/angristan/openvpn-install

### SSH into OpenVPN VM

```bash
ssh azureuser@<openvpn-vm-public-ip>
```

### Download and Run the Script

```bash
curl -O https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh
chmod +x openvpn-install.sh
./openvpn-install.sh interactive
```

### Answer the Prompts Exactly as Below

```
Endpoint type [1-2]: 1
  → IPv4

IPv4 address: 10.0.1.4  (shows the private IP — that's expected)

Public IPv4 address or hostname: <your-openvpn-vm-public-ip>
  → The script detects it's behind NAT and asks for the real public IP
  → Enter the Public IP of vm-openvpn from the portal

Client IP versions [1-3]: 1
  → IPv4 only

IPv4 subnet choice [1-2]: 1
  → Default 10.8.0.0/24

Port choice [1-3]: 1
  → Default 1194

Protocol [1-2]: 1
  → UDP

DNS [1-13]: 3
  → Cloudflare

Allow multiple devices per client? [y/n]: n

MTU choice [1-2]: 1
  → Default 1500

Authentication mode [1-2]: 1
  → PKI (Certificate Authority)

Customize encryption settings? [y/n]: n
```

Press any key to continue — script installs OpenVPN, sets up PKI, configures systemd service and iptables automatically.

### Create a Client Certificate

When prompted after install:

```
Client name: azure
  → or any name you prefer

Certificate validity (days): 3650

Select an option [1-2]: 1
  → Passwordless client
```

Script writes the `.ovpn` file to `/home/azureuser/azure.ovpn`

### Push VNet Route to VPN Clients

The script does NOT automatically push your VNet routes. Add this manually:

```bash
sudo nano /etc/openvpn/server/server.conf
```

Add this line anywhere in the file:
```
push "route 10.0.0.0 255.255.0.0"
```

Save (`Ctrl+X` → `Y` → `Enter`) then restart:
```bash
sudo systemctl restart openvpn-server@server
```

> Note the service name is `openvpn-server@server` (not `openvpn@server`) — the angristan script uses this naming.

### Copy VPN Config to Your Laptop

From your laptop (new terminal):
```bash
scp azureuser@<openvpn-vm-public-ip>:/home/azureuser/azure.ovpn ~/azure.ovpn
```

### Connect VPN

- **Windows**: Install OpenVPN GUI → right-click tray icon → Import → select `azure.ovpn` → Connect
- **Linux/Mac**: `sudo openvpn --config ~/azure.ovpn`

### Verify VPN is Working

Once connected, from your laptop:
```bash
ping 10.0.2.5
```
Should get responses — your laptop is now inside the VNet.

---

## Step 11 — Setup Backend VM

### SSH into Backend VM (directly via VPN — no jump box)

```bash
ssh azureuser@10.0.2.5
```

### Copy App Code to Backend VM

From your laptop with VPN connected:
```bash
scp -r <path-to-3-tier-app>/backend/ azureuser@10.0.2.5:/tmp/backend
```

### Install and Configure Backend (on vm-backend)

```bash
sudo mkdir -p /opt/backend
sudo chown azureuser:azureuser /opt/backend
cp -r /tmp/backend/* /opt/backend/

sudo apt update -y
sudo apt install -y python3 python3-pip python3-venv

cd /opt/backend
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
deactivate

# Set these before running the block below
KV_URL="https://3tier-kv-<unique>.vault.azure.net/"
STATIC_URL="https://3tierfrontend<unique>.z30.web.core.windows.net"

sudo tee /etc/systemd/system/backend.service > /dev/null <<EOF
[Unit]
Description=3-Tier Backend API
After=network.target

[Service]
User=azureuser
WorkingDirectory=/opt/backend
Environment="KEY_VAULT_URL=${KV_URL}"
Environment="FRONTEND_ORIGIN=${STATIC_URL}"
ExecStart=/opt/backend/venv/bin/python3 app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable backend
sudo systemctl start backend

sudo systemctl status backend
curl http://localhost:5001/health
```

Expected: `{"status": "ok", "service": "backend-api"}`

---

## Step 12 — Create Database Table

From vm-backend:
```bash
sudo apt install -y postgresql-client

psql "host=3tier-pg-<unique>.postgres.database.azure.com \
      dbname=appdb \
      user=pgadmin \
      password=<your-password> \
      sslmode=require"
```

```sql
CREATE TABLE items (
    id         SERIAL PRIMARY KEY,
    name       VARCHAR(255) NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);

INSERT INTO items (name) VALUES ('test-item');
SELECT * FROM items;
\q
```

---

## Step 13 — Verify End to End

```bash
# 1. Backend health via VPN
curl http://10.0.2.5:5001/health

# 2. Backend API via AppGW (public internet, no VPN needed)
curl http://<appgw-public-ip>/api/items

# 3. Frontend — open in browser
# https://3tierfrontend<unique>.z30.web.core.windows.net
# Items table should load, add/delete should work

# 4. Confirm PostgreSQL is private — disconnect VPN then try:
psql "host=3tier-pg-<unique>.postgres.database.azure.com dbname=appdb user=pgadmin password=<pw> sslmode=require"
# Should time out — no public access
```

---

## Summary

| Component | Subnet | Private Subnet | Public IP | Access |
|---|---|---|---|---|
| `vm-openvpn` | `public-subnet` | ❌ Off | ✅ Yes | Internet → UDP 1194 |
| `vm-backend` | `private-subnet` | ✅ On | ❌ No | Via VPN tunnel only |
| PostgreSQL | `db-subnet` | ✅ On | ❌ No | Via Backend VM only |
| Key Vault | Azure-managed | N/A | N/A | Managed Identity (RBAC) |
| Application Gateway | `appgw-subnet` | ❌ Off | ✅ Yes | Internet → port 80 |
| Blob Storage | Azure-managed | N/A | ✅ Yes | Public HTTPS static site |

**Access path into the VNet: OpenVPN only. No jump box, no bastion.**

---

## After Manual Steps Work

1. Note all resource IDs, IPs, names
2. Tear down manually created resources
3. Rebuild with Terraform using these steps as source of truth
