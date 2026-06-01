# Phase 03 — VPN VM (OpenVPN) for Private Resource Access

> **Lab:** APIM 3 — Public APIM → Private AGW → AKS (httpbin)

---

## Why VPN in this lab

> ⚠️ **VPN is MANDATORY in this lab — not optional.**
> AKS is deployed as a **private cluster** (created in Phase 00). The API server has no public endpoint.
> `kubectl` from your laptop will hang or refuse connection until the VPN tunnel is up.
> **Complete Phase 03 fully and verify VPN works before touching Phase 04.**

This lab has several private resources only reachable inside `vnet-myapp`:

| Resource | Private IP | Why unreachable without VPN |
|---|---|---|
| AKS API server (private cluster) | `10.0.1.x` (private endpoint) | **kubectl completely broken without VPN** |
| AGW private frontend | `10.0.3.4` | No public IP for debugging |
| AKS ILB | `10.0.1.50` | Internal only |
| PostgreSQL | `10.0.4.x` | No public access |
| Key Vault private endpoint | `10.0.1.x` | Phase 09 |

```
Your laptop
  ↓ OpenVPN tunnel (UDP 1194)
vpn-vm-apim3 (10.0.1.x in snet-aks, Static public IP)
  ↓ IP forwarding
vnet-myapp (10.0.0.0/16)
  ↓
kubectl get pods                   → AKS private API server ✅  ← REQUIRED
curl http://10.0.3.4/get          → AGW private ✅
psql pg-task10.postgres...         → PostgreSQL ✅
```

> **Why Azure DNS (168.63.129.16) is critical for private AKS:**
> The private cluster API server FQDN (`aks-myapp.hcp.southindia.azmk8s.io`) resolves to
> the private endpoint IP only when queried through Azure DNS from inside the VNet.
> If OpenVPN uses a different primary DNS (e.g. 8.8.8.8), the FQDN either fails to resolve
> or returns a NXDOMAIN — `kubectl` silently breaks even with the VPN tunnel up.
> **Primary DNS in the OpenVPN config MUST be `168.63.129.16`.**

---

## 3.1 Create VPN VM

**Portal:**
```
Virtual Machines → Create → Azure Virtual Machine

── Basics ────────────────────────────────────────────
   Resource Group    → rg-myapp
   VM Name           → vpn-vm-apim3
   Region            → South India
   Image             → Ubuntu Server 24.04 LTS - Gen2
   Size              → Standard_B2ts_v2 (2 vCPU, 1 GiB)
   Authentication    → Password
   Username          → azureuser
   Security type     → Trusted launch

── Networking ────────────────────────────────────────
   Virtual network   → vnet-myapp
   Subnet            → snet-aks (10.0.1.0/24)
   Public IP         → Create new
                        Name: pip-vpn-apim3
                        SKU: Standard
                        Assignment: Static   ← CRITICAL: must be static
   Accelerated networking → On
   Delete NIC when VM deleted → Enabled
   OS disk type      → Premium SSD LRS

→ Review + Create → Create
```

**CLI:**
```bash
az vm create \
  --resource-group $RESOURCE_GROUP \
  --name $VPN_VM_NAME \
  --location $LOCATION \
  --image Ubuntu2404 \
  --size Standard_B2ts_v2 \
  --vnet-name $VNET_NAME \
  --subnet $AKS_SUBNET \
  --public-ip-address $PIP_VPN \
  --public-ip-sku Standard \
  --public-ip-address-allocation Static \
  --admin-username azureuser \
  --admin-password 'VpnAdmin@Apim3!'
```

---

## 3.2 Enable IP forwarding on VM NIC

> ⚠️ Required — allows VM to route packets between the VPN tunnel and the VNet.

```bash
NIC_ID=$(az vm show \
  --resource-group $RESOURCE_GROUP \
  --name $VPN_VM_NAME \
  --query "networkProfile.networkInterfaces[0].id" -o tsv)

az network nic update --ids $NIC_ID --ip-forwarding true

# Verify — note: CLI property is enableIPForwarding (capital IP)
az network nic show --ids $NIC_ID --query "enableIPForwarding" -o tsv
# Expected: true ✅
```

**Portal alternative:**
```
Virtual Machines → vpn-vm-apim3 → Networking
→ click NIC name → Settings → IP configurations
→ Enable IP forwarding → ON → Save
```

---

## 3.3 NSG: allow UDP 1194 (OpenVPN)

```bash
az network nsg rule create \
  --resource-group $RESOURCE_GROUP \
  --nsg-name nsg-aks \
  --name Allow-OpenVPN \
  --priority 100 \
  --protocol Udp \
  --destination-port-ranges 1194 \
  --access Allow \
  --direction Inbound
```

**Portal:**
```
Network Security Groups → nsg-aks → Inbound security rules → + Add
   Source               → Any
   Destination port     → 1194
   Protocol             → UDP
   Action               → Allow
   Priority             → 100
   Name                 → Allow-OpenVPN
→ Add
```

---

## 3.4 Install OpenVPN inside VM

```bash
VPN_PUBLIC_IP=$(az network public-ip show \
  --resource-group $RESOURCE_GROUP \
  --name $PIP_VPN \
  --query ipAddress -o tsv)

echo "VPN public IP: $VPN_PUBLIC_IP"
ssh azureuser@$VPN_PUBLIC_IP
```

Once inside the VM:

```bash
# Enable OS-level IP forwarding
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# Download and run angristan's installer
wget https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh
chmod +x openvpn-install.sh
sudo su ./openvpn-install.sh interactive
```

**Installer prompts:**
```
IP address        → press Enter (auto-detected public IP)
Protocol          → 1 (UDP)
Port              → press Enter (1194)
DNS resolver      → 11 (Custom)
  Primary DNS     → 168.63.129.16   ← Azure DNS — resolves privatelink zones
  Secondary DNS   → 8.8.8.8
Compression       → n
Custom encryption → n
Client name       → apim3-client
```

> **Why Azure DNS as primary (168.63.129.16):**
> Once on VPN, you want to resolve `pg-task10.private.postgres.database.azure.com` to
> its private IP (`10.0.4.x`). Azure DNS handles this automatically from inside the VNet.

---

## 3.5 Download .ovpn file to laptop

```bash
# Run from your LOCAL machine (not the VM)
scp azureuser@$VPN_PUBLIC_IP:/root/apim3-client.ovpn ~/apim3-client.ovpn
```

---

## 3.6 Connect from laptop

**Windows / Mac:**
```
1. Download OpenVPN Connect: https://openvpn.net/client/
2. Import → apim3-client.ovpn
3. Click Connect ✅
```

**Linux:**
```bash
sudo apt install openvpn -y
sudo openvpn --config ~/apim3-client.ovpn
```

---

## 3.7 Verify VPN is working

```bash
ping 10.0.1.1       # VNet gateway reachable ✅

# Verify Azure DNS is resolving through the tunnel (critical for private AKS)
# Run from your laptop while VPN is connected:
nslookup aks-myapp.hcp.southindia.azmk8s.io
# Must return a 10.0.x.x address — if it returns NXDOMAIN or a public IP,
# OpenVPN DNS is not set to 168.63.129.16 → re-run installer with Custom DNS

# After Phase 04 (AKS credentials fetched):
kubectl get nodes
# Must return nodes ✅ — if it hangs, DNS is not resolving correctly via tunnel

# After Phase 06 (AGW is created):
curl http://10.0.3.4/get
# Expected: httpbin JSON ✅  confirms AGW → ILB → pod chain works

# After Phase 08 (PostgreSQL):
psql -h pg-task10.postgres.database.azure.com -U pgadmin -d postgres
# Must connect → confirms DNS resolves to 10.0.4.x via Azure DNS ✅
```

> **Troubleshooting: VPN connected but kubectl still hangs**
> 1. Check DNS: `nslookup aks-myapp.hcp.southindia.azmk8s.io` — must return `10.0.x.x`
> 2. If it returns public IP or NXDOMAIN → re-run angristan installer, choose Custom DNS, enter `168.63.129.16` as primary
> 3. Regenerate `.ovpn` file and reconnect
> 4. On Windows, check if VPN adapter has DNS suffix set: `ipconfig /all` — look for `tap` adapter

---

## Phase 03 complete? ⬜ VPN connected, `ping 10.0.1.1` works, `nslookup aks-myapp.hcp.southindia.azmk8s.io` returns a private IP.
