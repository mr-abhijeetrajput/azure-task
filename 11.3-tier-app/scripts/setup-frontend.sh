#!/bin/bash
# setup-frontend.sh — Run from your LOCAL MACHINE (not the VM)
# Uploads the static frontend (index.html) to Azure Blob Storage
# and enables static website hosting.
#
# PREREQ:
#   - az cli logged in (az login)
#   - AppGW public IP known
#   - Storage account created (manually via portal or az cli)
#
# Usage:
#   export STORAGE_ACCOUNT="mystorageacct"
#   export APPGW_PUBLIC_IP="1.2.3.4"
#   export RESOURCE_GROUP="3tier-rg"          # optional, for account lookup
#   bash scripts/setup-frontend.sh

set -e
echo "=== 3-Tier Frontend — Blob Static Site Upload ==="

# --- Inputs ---
if [ -z "$STORAGE_ACCOUNT" ]; then
    read -rp "Enter storage account name: " STORAGE_ACCOUNT
fi

if [ -z "$APPGW_PUBLIC_IP" ]; then
    read -rp "Enter AppGW public IP (or DNS): " APPGW_PUBLIC_IP
fi

FRONTEND_SRC="frontend/templates/index.html"

if [ ! -f "$FRONTEND_SRC" ]; then
    echo "ERROR: Run from 3-tier-app/ directory — $FRONTEND_SRC not found"
    exit 1
fi

# --- Step 1: Enable static website hosting on the storage account ---
echo "[1/4] Enabling static website hosting..."
az storage blob service-properties update \
    --account-name "$STORAGE_ACCOUNT" \
    --static-website \
    --index-document "index.html" \
    --auth-mode login

# --- Step 2: Get the static site URL ---
STATIC_SITE_URL=$(az storage account show \
    --name "$STORAGE_ACCOUNT" \
    --query "primaryEndpoints.web" \
    -o tsv | tr -d '[:space:]')

echo "Static site URL: $STATIC_SITE_URL"

# --- Step 3: Patch APPGW_PUBLIC_IP into index.html before upload ---
echo "[2/4] Patching APPGW_PUBLIC_IP into index.html..."
TMP_HTML=$(mktemp /tmp/index_XXXXXX.html)
sed "s|http://APPGW_PUBLIC_IP|http://$APPGW_PUBLIC_IP|g" "$FRONTEND_SRC" > "$TMP_HTML"

# --- Step 4: Upload to $web container ---
echo "[3/4] Uploading index.html to \$web container..."
az storage blob upload \
    --account-name "$STORAGE_ACCOUNT" \
    --container-name '$web' \
    --name "index.html" \
    --file "$TMP_HTML" \
    --content-type "text/html" \
    --overwrite \
    --auth-mode login

rm "$TMP_HTML"

# --- Step 5: Done ---
echo "[4/4] Done."
echo ""
echo "=== Frontend Deployed ==="
echo "Static site URL:  $STATIC_SITE_URL"
echo "Open in browser:  $STATIC_SITE_URL"
echo ""
echo "Next steps:"
echo "  1. Make sure backend is running:  curl http://$APPGW_PUBLIC_IP/api/items"
echo "  2. If CORS errors in browser — update FRONTEND_ORIGIN on backend-vm:"
echo "       sudo systemctl edit backend"
echo "       Add: Environment=\"FRONTEND_ORIGIN=$STATIC_SITE_URL\""
echo "       sudo systemctl restart backend"
