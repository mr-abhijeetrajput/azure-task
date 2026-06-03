"""
Frontend — Flask app that serves HTML and calls the backend API.
Reads backend URL from environment variable (set via App Settings or setup script).
"""
from flask import Flask, render_template, request, redirect, url_for, flash
import os
import requests as http_requests

app = Flask(__name__)
app.secret_key = "frontend-secret"

# Backend API URL — injected via environment variable
# In production: set via App Settings or systemd unit file
BACKEND_URL = os.environ.get("BACKEND_URL", "http://10.0.2.5:5001")


@app.route("/")
def index():
    """Fetch items from backend API and render page."""
    items = []
    error = None
    try:
        resp = http_requests.get(f"{BACKEND_URL}/api/items", timeout=5)
        resp.raise_for_status()
        items = resp.json().get("items", [])
    except Exception as e:
        error = f"Could not reach backend API: {e}"
    return render_template("index.html", items=items, error=error, backend_url=BACKEND_URL)


@app.route("/add", methods=["POST"])
def add_item():
    """Send new item to backend API."""
    name = request.form.get("name", "").strip()
    if not name:
        flash("Item name cannot be empty", "error")
        return redirect(url_for("index"))
    try:
        resp = http_requests.post(
            f"{BACKEND_URL}/api/items",
            json={"name": name},
            timeout=5
        )
        resp.raise_for_status()
        flash(f"Added: {name}", "success")
    except Exception as e:
        flash(f"Failed to add item: {e}", "error")
    return redirect(url_for("index"))


@app.route("/delete/<int:item_id>", methods=["POST"])
def delete_item(item_id):
    """Ask backend API to delete an item."""
    try:
        resp = http_requests.delete(f"{BACKEND_URL}/api/items/{item_id}", timeout=5)
        resp.raise_for_status()
        flash(f"Deleted item #{item_id}", "success")
    except Exception as e:
        flash(f"Failed to delete: {e}", "error")
    return redirect(url_for("index"))


@app.route("/health")
def health():
    return "OK", 200


if __name__ == "__main__":
    print(f"Frontend starting — Backend URL: {BACKEND_URL}")
    app.run(host="0.0.0.0", port=5000, debug=False)
