#!/bin/bash
# setup-backend.sh — Run on backend-vm via jump box
# Sets up Python, Flask backend API, and systemd service
# PREREQ: KEY_VAULT_URL must be set as env var before running
#
# Optional: set FRONTEND_ORIGIN to lock CORS to your blob static site URL
# e.g. export FRONTEND_ORIGIN="https://mystorageacct.z30.web.core.windows.net"
# If not set, defaults to * (allow all — fine for lab, restrict in prod)

set -e
echo "=== 3-Tier Backend Setup ==="

APP_DIR="/opt/backend"
sudo mkdir -p $APP_DIR
sudo chown azureuser:azureuser $APP_DIR

if [ -f "backend/app.py" ]; then
    cp -r backend/* $APP_DIR/
else
    echo "ERROR: Run from 3-tier-app/ directory"
    exit 1
fi

echo "[1/4] Installing dependencies..."
sudo apt update -y
sudo apt install -y python3 python3-pip python3-venv

echo "[2/4] Creating virtualenv..."
cd $APP_DIR
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
deactivate

if [ -z "$KEY_VAULT_URL" ]; then
    read -rp "Enter Key Vault URL (e.g. https://mylab-kv-xxx.vault.azure.net): " KEY_VAULT_URL
fi

if [ -z "$FRONTEND_ORIGIN" ]; then
    read -rp "Enter blob static site URL for CORS (or press Enter for *): " FRONTEND_ORIGIN
    FRONTEND_ORIGIN="${FRONTEND_ORIGIN:-*}"
fi

echo "[3/4] Creating systemd service..."
sudo tee /etc/systemd/system/backend.service > /dev/null <<EOF
[Unit]
Description=3-Tier Backend API
After=network.target

[Service]
User=azureuser
WorkingDirectory=$APP_DIR
Environment="KEY_VAULT_URL=$KEY_VAULT_URL"
Environment="FRONTEND_ORIGIN=$FRONTEND_ORIGIN"
ExecStart=$APP_DIR/venv/bin/python3 app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "[4/4] Starting service..."
sudo systemctl daemon-reload
sudo systemctl enable backend
sudo systemctl start backend

echo ""
echo "=== Backend Setup Complete ==="
echo "Status:         $(sudo systemctl is-active backend)"
echo "Health:         curl http://localhost:5001/health"
echo "CORS origin:    $FRONTEND_ORIGIN"
echo "Logs:           sudo journalctl -u backend -f"
