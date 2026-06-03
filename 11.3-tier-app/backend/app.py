"""
Backend API — Flask REST API that talks to PostgreSQL.
Reads DB credentials from Azure Key Vault via Managed Identity (no hardcoded secrets).
CORS enabled so the static frontend hosted on Blob Storage can call this API.
"""
from flask import Flask, jsonify, request
from flask_cors import CORS
import os
import psycopg2
from azure.identity import ManagedIdentityCredential
from azure.keyvault.secrets import SecretClient

app = Flask(__name__)

# Allow requests from the blob storage static site origin
# Replace with your actual storage account static site URL after deploy
FRONTEND_ORIGIN = os.environ.get("FRONTEND_ORIGIN", "*")
CORS(app, origins=FRONTEND_ORIGIN)

# --- Key Vault client (Managed Identity — no secrets in code!) ---
KV_URL = os.environ.get("KEY_VAULT_URL")   # e.g. https://mylab-kv-xxx.vault.azure.net

def get_secret(name: str) -> str:
    credential = ManagedIdentityCredential()
    client = SecretClient(vault_url=KV_URL, credential=credential)
    return client.get_secret(name).value

# --- DB connection (credentials read from Key Vault at startup) ---
def get_db_connection():
    return psycopg2.connect(
        host=get_secret("db-host"),
        database="appdb",
        user=get_secret("db-user"),
        password=get_secret("db-password"),
        sslmode="require"
    )

# --- Routes ---
@app.route("/health")
def health():
    return jsonify({"status": "ok", "service": "backend-api"}), 200


@app.route("/api/items", methods=["GET"])
def list_items():
    """Return all items from PostgreSQL."""
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("SELECT id, name, created_at FROM items ORDER BY created_at DESC;")
        rows = cur.fetchall()
        cur.close()
        conn.close()
        items = [{"id": r[0], "name": r[1], "created_at": str(r[2])} for r in rows]
        return jsonify({"items": items, "count": len(items)})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/items", methods=["POST"])
def create_item():
    """Create a new item in PostgreSQL."""
    data = request.get_json()
    if not data or "name" not in data:
        return jsonify({"error": "name is required"}), 400
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("INSERT INTO items (name) VALUES (%s) RETURNING id;", (data["name"],))
        item_id = cur.fetchone()[0]
        conn.commit()
        cur.close()
        conn.close()
        return jsonify({"id": item_id, "name": data["name"]}), 201
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/items/<int:item_id>", methods=["DELETE"])
def delete_item(item_id):
    """Delete an item from PostgreSQL."""
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("DELETE FROM items WHERE id = %s;", (item_id,))
        conn.commit()
        cur.close()
        conn.close()
        return jsonify({"deleted": item_id}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500


if __name__ == "__main__":
    if not KV_URL:
        print("ERROR: Set KEY_VAULT_URL environment variable")
        exit(1)
    print(f"Backend API starting — Key Vault: {KV_URL}")
    print(f"CORS origin: {FRONTEND_ORIGIN}")
    app.run(host="0.0.0.0", port=5001, debug=False)
