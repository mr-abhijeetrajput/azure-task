# VMSS Behind Public Load Balancer + Autoscaling
### Scale Set instances with no public IP — internet traffic via Public LB only, CPU-based autoscale

> **What you will build:**
> `rg-task01` holds a VMSS (`vmss-fintrack`) on `subnet-backend` with **no public IP** on any instance.
> A **Public Load Balancer** (`lb-fintrack`) sits in front with a public frontend IP.
> **No jumpbox needed** — instance access is via Azure Serial Console.
> Autoscale rules scale out when CPU > 70% and scale in when CPU < 30%.

---

## Why Public LB instead of Internal LB?

| | Internal Load Balancer (ILB) | Public Load Balancer |
|---|---|---|
| **Frontend IP** | Private RFC 1918 (e.g. `10.10.2.10`) | Public IP reachable from the internet |
| **Who can reach it** | Only resources inside the same VNet (or peered VNets) | Anyone on the internet |
| **Use case** | Backend tiers, databases, microservices talking to each other inside Azure | Web servers, APIs, any service that needs to be publicly accessible |
| **This task** | ❌ You can only test via Serial Console `curl` — no browser, no external tools | ✅ You can open a browser, run `curl` from your laptop, use load testing tools |

**Short answer:** The original ILB design is correct for production security (private backend), but for a **lab/learning task** a Public LB is far more practical — you can actually hit the endpoint from your own machine and see it work end-to-end. The VMSS instances still have **no public IP** — only the LB frontend is public.

---

## Architecture

```
Internet
  │
  ▼
lb-fintrack  (Public Load Balancer — Standard SKU)
  ├── Frontend IP : <public-ip>  (dynamic public, assigned at creation)
  ├── Backend Pool: vmss-fintrack instances
  ├── Health Probe: HTTP :80 /health  (interval 15s, threshold 2)
  └── LB Rule     : TCP 80 → 80
  │
  ▼
vnet-task01 (10.10.0.0/16)  —  rg-task01  —  southindia
│
└── subnet-backend   (10.10.2.0/24)
    └── vmss-fintrack  (VM Scale Set)
        ├── Instances : 2 (min) → 5 (max)
        ├── No public IP on any instance
        ├── Ubuntu 22.04 · nginx · /health endpoint
        ├── Password auth enabled (required for Serial Console)
        └── Autoscale
            ├── Scale OUT: CPU > 70% avg over 5 min → +1 instance
            └── Scale IN : CPU < 30% avg over 5 min → -1 instance

Instance access (no jumpbox):
  Azure Portal → vmss-fintrack → Instances → pick instance → Serial Console

Load test traffic flow:
  Your browser / curl laptop  →  <public-ip>:80  →  Public LB  →  VMSS backend pool
```

---

## Why Public LB + VMSS (No Public IPs on Instances)

| Concept | Explanation |
|---|---|
| No public IP on VMSS | Instances are unreachable directly from the internet. Only the LB frontend is exposed. |
| Public Load Balancer | Accepts inbound traffic from the internet and distributes it to backend VMSS instances. |
| Standard SKU (mandatory) | Basic LB does not support VMSS + autoscale. Always use Standard for both. |
| Health probe | LB removes unhealthy instances from the backend pool automatically. |
| CPU autoscaling | VMSS adds/removes VMs based on metric thresholds — no over-provisioning. |
| Serial Console | Direct browser-based console via Azure Portal — no SSH, no public IP, no jumpbox needed. |
| Cloud-init | Bootstraps nginx + `/health` endpoint on every new VMSS instance automatically. |

---

## PRE-STEP — Environment Variables

```bash
LOCATION="southindia"
RG="rg-task01"
VNET="vnet-task01"
SUBNET_FE="subnet-frontend"
SUBNET_BE="subnet-backend"
LB_NAME="lb-fintrack"
LB_PIP_NAME="pip-lb-fintrack"
VMSS_NAME="vmss-fintrack"
ADMIN_USER="azureuser"
ADMIN_PASSWORD="FinTrack@lab2024!"   # needed for Serial Console password login
```

---

## Step 0 — Create Resource Group, VNet, and Subnet

### 0a — Create Resource Group

```bash
az group create \
  --name $RG \
  --location $LOCATION
```

### 0b — Create Virtual Network

```bash
az network vnet create \
  --resource-group $RG \
  --name $VNET \
  --location $LOCATION \
  --address-prefixes 10.10.0.0/16
```

> Creates `vnet-task01` with address space `10.10.0.0/16`. Both subnets (`subnet-frontend` and `subnet-backend`) will carve out ranges from this space.

### 0c — Create Backend Subnet

> Only `subnet-backend` is needed for this task. If it already exists, skip.

```bash
az network vnet subnet create \
  --resource-group $RG \
  --vnet-name $VNET \
  --name $SUBNET_BE \
  --address-prefixes 10.10.2.0/24
```

---

## Step 1 — Create the Public Load Balancer

### 1a — Create a Public IP for the LB frontend

```bash
az network public-ip create \
  --resource-group $RG \
  --name $LB_PIP_NAME \
  --location $LOCATION \
  --sku Standard \
  --allocation-method Static
```

> Standard SKU LB requires a Standard SKU Public IP. Basic SKU public IPs are not compatible.

### 1b — Create the Public Load Balancer with frontend public IP

```bash
az network lb create \
  --resource-group $RG \
  --name $LB_NAME \
  --location $LOCATION \
  --sku Standard \
  --public-ip-address $LB_PIP_NAME \
  --frontend-ip-name fe-config \
  --backend-pool-name be-pool
```

> No `--vnet-name` or `--subnet` needed — the Public LB frontend lives on a public IP, not inside a subnet.

### 1c — Health probe (HTTP GET /health on port 80)

```bash
az network lb probe create \
  --resource-group $RG \
  --lb-name $LB_NAME \
  --name probe-http \
  --protocol Http \
  --port 80 \
  --path /health \
  --interval 15 \
  --threshold 2
```

### 1d — Load balancing rule (TCP 80 → 80)

```bash
az network lb rule create \
  --resource-group $RG \
  --lb-name $LB_NAME \
  --name rule-http \
  --protocol Tcp \
  --frontend-port 80 \
  --backend-port 80 \
  --frontend-ip-name fe-config \
  --backend-pool-name be-pool \
  --probe-name probe-http \
  --idle-timeout 4
```

> **Standard SKU is mandatory.** Basic LB does not support VMSS autoscale.

---

## Step 2 — Create the VMSS (No Public IP, nginx via cloud-init)

### 2a — Prepare cloud-init (save as `/tmp/cloud-init.yaml` locally)

```yaml
#cloud-config
packages:
  - nginx
runcmd:
  - systemctl enable nginx
  - systemctl start nginx
  - echo 'ok' > /var/www/html/health
  - nginx -s reload
```

### 2b — Create VMSS attached to Public LB

```bash
az vmss create \
  --resource-group $RG \
  --name $VMSS_NAME \
  --location $LOCATION \
  --image Ubuntu2204 \
  --vm-sku Standard_B1s \
  --instance-count 2 \
  --vnet-name $VNET \
  --subnet $SUBNET_BE \
  --public-ip-address "" \
  --lb $LB_NAME \
  --backend-pool-name be-pool \
  --admin-username $ADMIN_USER \
  --admin-password $ADMIN_PASSWORD \
  --custom-data /tmp/cloud-init.yaml \
  --upgrade-policy-mode Automatic
```

> `--public-ip-address ""` explicitly disables public IPs on all VMSS instances — only the LB frontend is public.
> `--lb` attaches VMSS NICs to the Public LB backend pool during creation.
> `--admin-password` instead of `--generate-ssh-keys` is required — Serial Console uses password auth.

---

## Step 3 — Configure Autoscale Policy

### 3a — Create autoscale settings on the VMSS

```bash
VMSS_ID=$(az vmss show \
  --resource-group $RG \
  --name $VMSS_NAME \
  --query id -o tsv)

az monitor autoscale create \
  --resource-group $RG \
  --name autoscale-fintrack \
  --resource $VMSS_ID \
  --min-count 2 \
  --max-count 5 \
  --count 2
```

### 3b — Scale-out rule: CPU > 70% for 5 min → add 1 instance

```bash
az monitor autoscale rule create \
  --resource-group $RG \
  --autoscale-name autoscale-fintrack \
  --condition "Percentage CPU > 70 avg 5m" \
  --scale out 1
```

### 3c — Scale-in rule: CPU < 30% for 5 min → remove 1 instance

```bash
az monitor autoscale rule create \
  --resource-group $RG \
  --autoscale-name autoscale-fintrack \
  --condition "Percentage CPU < 30 avg 5m" \
  --scale in 1
```

> Both rules are required. Without scale-in, VMSS grows and never shrinks — a cost leak.

---

## Step 4 — Access Instances via Serial Console (No Jumpbox)

Serial Console gives you a direct terminal into any VMSS instance through the Azure Portal — no SSH, no public IP, no jumpbox.

### 4a — Enable Serial Console (subscription-level, one time)

> Serial Console is usually enabled by default. If it's greyed out, your subscription may have it disabled.

```bash
# Check if boot diagnostics is enabled on the VMSS (required for Serial Console)
az vmss show \
  --resource-group $RG \
  --name $VMSS_NAME \
  --query "virtualMachineProfile.diagnosticsProfile.bootDiagnostics"
```

If `enabled` is `false` or null:

```bash
az vmss update \
  --resource-group $RG \
  --name $VMSS_NAME \
  --set virtualMachineProfile.diagnosticsProfile.bootDiagnostics.enabled=true

# Reimage instances to apply the update
az vmss reimage \
  --resource-group $RG \
  --name $VMSS_NAME
```

### 4b — Open Serial Console in Portal

1. Portal → **Virtual machine scale sets** → `vmss-fintrack`.
2. Left menu → **Instances** → click any instance (e.g. `vmss-fintrack_0`).
3. Left menu → **Serial console**.
4. Login prompt appears — enter `azureuser` and the password set in Step 2.

```
ubuntu login: azureuser
Password: FinTrack@lab2024!
```

> Serial Console works even when the instance has no public IP, no NSG SSH rule, and the VNet has no internet route.

---

## Step 5 — Verify Health Probe and LB Connectivity

### 5a — Get the Public LB frontend IP

```bash
# Retrieve the public IP assigned to the LB
LB_PUBLIC_IP=$(az network public-ip show \
  --resource-group $RG \
  --name $LB_PIP_NAME \
  --query ipAddress -o tsv)
echo "LB Public IP: $LB_PUBLIC_IP"
```

### 5b — From your local machine: curl the LB public IP

```bash
# From your laptop / local machine — hits Public LB → VMSS backend pool → nginx
curl http://$LB_PUBLIC_IP/health
# Expected: ok

# Run a few times to confirm LB is distributing across instances
curl -s http://$LB_PUBLIC_IP/
```

You can also open `http://<LB_PUBLIC_IP>` directly in your browser and see the nginx welcome page.

### 5c — From inside the instance via Serial Console (optional)

Portal → `vmss-fintrack` → **Instances** → `vmss-fintrack_0` → **Serial console** → login.

```bash
# From inside any VMSS instance via Serial Console
curl http://$LB_PUBLIC_IP/health
# Expected: ok
```

### 5c — Verify VMSS instance IPs (from local machine CLI)

```bash
# List private IPs — no public IPs should appear
az vmss nic list \
  --resource-group $RG \
  --vmss-name $VMSS_NAME \
  --query "[].ipConfigurations[0].{PrivateIP:privateIPAddress, PublicIP:publicIPAddress}" \
  -o table

# Expected: PrivateIP = 10.10.2.x  |  PublicIP = None
```

---

## Step 6 — Test Autoscale (CPU Load Generation)

> No jumpbox needed. Use Serial Console for interactive access or `az vmss run-command invoke` for non-interactive commands across all instances.

### Option A — CPU stress via Serial Console (interactive)

```bash
# Inside instance via Serial Console
sudo apt-get install -y stress
stress --cpu 4 --timeout 600 &

# Open Serial Console on the second instance and repeat
# Both instances pegged at high CPU triggers the scale-out rule
```

### Option B — CPU stress via run-command (recommended — no clicking per instance)

```bash
# Run stress on all VMSS instances (from local machine)
for INSTANCE_ID in $(az vmss list-instances \
  --resource-group $RG \
  --name $VMSS_NAME \
  --query "[].instanceId" -o tsv); do
  az vmss run-command invoke \
    --resource-group $RG \
    --name $VMSS_NAME \
    --command-id RunShellScript \
    --instance-id $INSTANCE_ID \
    --scripts "sudo apt-get install -y stress && stress --cpu 4 --timeout 600 &"
done
```

### 6c — Watch instance count change in real time

```bash
# Poll every 30 seconds
watch -n 30 'az vmss list-instances \
  --resource-group $RG \
  --name $VMSS_NAME \
  --query "[].{ID:instanceId, State:provisioningState}" \
  -o table'

# Check autoscale activity log
az monitor activity-log list \
  --resource-group $RG \
  --offset 1h \
  --query "[?contains(operationName.value,'autoscale')].{Time:eventTimestamp, Op:operationName.value, Status:status.value}" \
  -o table
```

> Scale-out takes ~5 minutes after CPU crosses the threshold (evaluation window).
> Scale-in takes another ~5 minutes after CPU drops. This is by design — cooldown prevents thrashing.

---

## Step 7 — Verify Scale-Out and Scale-In

```bash
# Should show 3, 4, or 5 instances (up from 2)
az vmss list-instances \
  --resource-group $RG \
  --name $VMSS_NAME \
  --query "[].{ID:instanceId, State:provisioningState}" \
  -o table

# Check current capacity
az vmss show \
  --resource-group $RG \
  --name $VMSS_NAME \
  --query "sku.capacity" \
  -o tsv
```

Stop the stress load (via Serial Console: `kill %1` or just close the stress process) — VMSS should scale back in to 2 instances after ~5 minutes.

---

## Azure Portal — Manual Steps

### Step 1 — Public Load Balancer

1. **Load balancers** → **Create**.
2. Type: **Public**, SKU: **Standard**, Tier: **Regional**, Region: **South India**, RG: `rg-task01`.
3. **Frontend IP configuration** → Add: Name `fe-config`, Public IP address → **Create new** → Name `pip-lb-fintrack`, SKU **Standard**, Assignment **Static**.
4. **Backend pools** → Add: Name `be-pool` (leave empty; VMSS attaches at creation).
5. **Health probes** → Add: Name `probe-http`, Protocol **HTTP**, Port **80**, Path `/health`, Interval **15**, Threshold **2**.
6. **Load balancing rules** → Add with these settings:
   - Name: `rule-http`
   - Protocol: **TCP**
   - Frontend port: **80**
   - Backend port: **80**
   - Backend pool: `be-pool`
   - Health probe: `probe-http` ⚠️ *create the probe in step 5 first — the rule requires it*
   - Session persistence: **None**
   - Idle timeout: **4** minutes
   - Enable TCP Reset: **unchecked**
   - Enable Floating IP: **unchecked**
   - Outbound SNAT: ✅ **Use outbound rules to provide backend pool members access to the internet** (recommended, already selected by default)
7. **Inbound NAT rules** → **Skip** — we use Serial Console for instance access, not SSH through the LB.
8. **Outbound rules** → **Skip** — outbound internet access for VMSS instances is already covered by the SNAT option selected in the LB rule above.

### Step 2 — VMSS

1. **Virtual machine scale sets** → **Create**.
2. **Basics** tab:
   - RG: `rg-task01`, Name: `vmss-fintrack`, Region: **South India**
   - Image: **Ubuntu Server 22.04 LTS**, Size: **Standard B1s**
   - Initial instance count: **1** (min quota for this size)
   - Authentication: **Password** → username `azureuser`, password `FinTrack@lab2024!`
3. **Networking** tab:
   - VNet: `vnet-task01`, Subnet: `subnet-backend`
   - **Public IP per instance: None** ⚠️ *make sure this is set to None — instances must not have public IPs*
   - **Load balancing options: Azure Load Balancer** ⚠️ *this is critical — do not skip*
   - **Select a load balancer**: `lb-fintrack`
   - **Select a backend pool**: `be-pool`
4. **Scaling** tab: leave as-is for now — autoscale is configured separately in Step 3.
5. **Management** tab:
   - Boot diagnostics: **Enable with managed storage account** ⚠️ *required for Serial Console*
   - Everything else: leave as default
6. **Advanced** tab → **Custom data** field — paste the cloud-init YAML below exactly as shown:

   ```yaml
   #cloud-config
   packages:
     - nginx
   runcmd:
     - systemctl enable nginx
     - systemctl start nginx
     - echo 'ok' > /var/www/html/health
     - nginx -s reload
   ```

   > ⚠️ This is the most commonly missed step. If Custom data is left empty, nginx will not be installed on any instance, the health probe will fail, and the LB will mark all instances as unhealthy. Verify the **Custom data** field is not blank before clicking Review + Create.

7. **Review + Create** → **Create**.

> ⚠️ Selecting the LB here is what automatically registers all VMSS instance NICs into `be-pool`. If you skip this, the backend pool stays empty and the LB has nothing to route traffic to.

### Step 3 — Autoscale in Portal

1. Open `vmss-fintrack` → **Scaling**.
2. Switch to **Custom autoscale** → Default profile.
3. Instance limits: Min **2**, Max **5**, Default **2**.
4. **Add rule**: Metric `Percentage CPU`, Operator `>`, Threshold `70`, Duration `5 min`, Action **Increase count by 1**.
5. **Add rule**: Metric `Percentage CPU`, Operator `<`, Threshold `30`, Duration `5 min`, Action **Decrease count by 1**.
6. **Save**.

### Step 4 — Enable Serial Console

1. Portal → `vmss-fintrack` → **Instances** → click any instance.
2. Left menu → **Serial console** — if it loads a terminal prompt, it's already enabled.
3. If disabled: instance → **Boot diagnostics** → **Enable** with managed storage account → **Save**.
4. Login: `azureuser` / `FinTrack@lab2024!`

### Steps 5–7 — Testing

1. Get LB public IP: Portal → `lb-fintrack` → **Frontend IP configuration** → copy the IP.
2. From your laptop: `curl http://<LB_PUBLIC_IP>/health` → expected: `ok`. Or open in a browser.
2. Run stress: `sudo apt-get install -y stress && stress --cpu 4 --timeout 600 &`
3. Repeat on `vmss-fintrack_1` via its own Serial Console tab.
4. Portal: `vmss-fintrack` → **Instances** blade — count increases after ~5 min.
5. Portal: `vmss-fintrack` → **Scaling** → **Run history** — shows scale events.
6. Kill stress → instance count drops back to 2 after ~5 min.

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `curl http://<LB_PUBLIC_IP>` times out from laptop | NSG on `subnet-backend` missing inbound rule for port 80 | Add inbound NSG rule: allow TCP 80 from `Internet` (or `*`) to `10.10.2.0/24` |
| Serial Console shows blank screen | Boot diagnostics not enabled | Instance → **Boot diagnostics** → Enable → Save → reimage instance |
| Serial Console login rejected | VMSS created with SSH keys, no password set | `az vmss run-command invoke` → `echo 'azureuser:FinTrack@lab2024!' \| sudo chpasswd` |
| Health probe unhealthy in portal | nginx not running or `/health` file missing | Serial Console → `systemctl status nginx` and `cat /var/www/html/health` |
| VMSS create fails with LB SKU mismatch | Mixing Basic LB with Standard VMSS | Use **Standard SKU** for both LB and VMSS — never mix |
| Instance count stays at 2 | CPU not crossing threshold or autoscale rules not saved | Serial Console → run stress manually; verify autoscale in Monitor → Autoscale |
| Scale-out not triggering | 5-minute evaluation window not elapsed | Wait the full window; check Monitor activity log for autoscale events |
| `az vmss run-command` on `--instance-id "*"` errors | Wildcard not supported in some CLI versions | Loop over instance IDs: `az vmss list-instances --query "[].instanceId"` |

---

## Cleanup

> Run only task-09-specific deletes if `rg-task01` is shared with other tasks.

```bash
az vmss delete --resource-group $RG --name $VMSS_NAME --yes --no-wait
az network lb delete --resource-group $RG --name $LB_NAME
az network public-ip delete --resource-group $RG --name $LB_PIP_NAME
az monitor autoscale delete --resource-group $RG --name autoscale-fintrack
# To also remove the VNet and RG (only if not shared with other tasks)
az network vnet delete --resource-group $RG --name $VNET
az group delete --name $RG --yes --no-wait
```

---

## Key Concepts Summary

| Concept | Azure Resource | Why It Matters |
|---|---|---|
| Private backend tier | VMSS with `--public-ip-address ""` | No direct internet access to compute |
| Public Load Balancer | Standard Public LB, public frontend IP | Accepts internet traffic and distributes to VMSS instances |
| Health probe | HTTP on `/health` | ILB auto-removes failed instances |
| Horizontal autoscale | Monitor Autoscale on VMSS | Handles load spikes without over-provisioning |
| Serial Console | Azure Portal → instance → Serial console | Direct terminal access with no public IP, no SSH, no jumpbox |
| Cloud-init | `--custom-data` on VMSS | Auto-bootstraps nginx on every new instance |
| Standard SKU | LB + VMSS | Required for autoscale; Basic LB blocks it |
