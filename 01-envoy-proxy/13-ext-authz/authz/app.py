"""Tiny HTTP authorization service for Envoy's ext_authz filter.

Envoy forwards the (filtered) request to this service. We:
 - inspect headers + path
 - return 200 to allow (optionally with extra headers to inject upstream)
 - return non-2xx (typically 401 or 403) to deny

Toy policy:
   /admin/*       — requires x-user-role: admin
   /protected/*   — requires any non-empty x-user-id
   anything else  — allowed
"""

import os
from flask import Flask, request, jsonify

app = Flask(__name__)


@app.route("/", defaults={"path": ""}, methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
@app.route("/<path:path>", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
def check(path):
    user = request.headers.get("x-user-id", "")
    role = request.headers.get("x-user-role", "user")
    p = "/" + path  # reconstruct original path

    if p.startswith("/admin"):
        if role != "admin":
            return jsonify(deny="needs role=admin"), 403
        return "", 200, {"x-authz-decision": "admin-allowed"}

    if p.startswith("/protected"):
        if not user:
            return jsonify(deny="missing x-user-id"), 401
        return "", 200, {"x-authz-decision": f"allowed-for-{user}"}

    return "", 200, {"x-authz-decision": "unmetered"}


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8000")))
