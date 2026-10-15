"""
Web Application A — stateless Python/Flask microservice
Endpoints:
  GET  /status          → health check (no auth)
  GET  /message         → fetch key/value from Web App B (static secret required)
  POST /spike           → CPU spike to trigger HPA (static secret required)

Auth: callers send "Authorization: <API_SECRET>"; compared in constant time.
"""

import os
import json
import math
import time
import hmac
import logging
import threading
import functools

import requests
from flask import Flask, jsonify, request, g

app = Flask(__name__)

# ---------------------------------------------------------------------------
# Configuration (injected via ConfigMap / Secrets)
# ---------------------------------------------------------------------------
APP_NAME      = os.environ.get("APP_NAME", "web-app-a")
APP_ENV       = os.environ.get("APP_ENV", "poc")
WEB_APP_B_URL = os.environ.get("WEB_APP_B_URL", "http://web-app-b.web-app-b.svc.cluster.local:8080")
API_SECRET    = os.environ.get("API_SECRET", "")    # injected from k8s Secret
SPIKE_SECONDS = int(os.environ.get("SPIKE_SECONDS", "20"))


# ---------------------------------------------------------------------------
# Audit logger — structured JSON to stdout, picked up by the pod log collector
# ---------------------------------------------------------------------------
_audit = logging.getLogger("audit")
logging.basicConfig(level=logging.INFO, format="%(message)s")


@app.before_request
def _start_timer():
    g.start_time = time.monotonic()


@app.after_request
def _audit_log(response):
    duration_ms = round((time.monotonic() - g.get("start_time", time.monotonic())) * 1000, 2)
    record = {
        "audit": True,
        "app": APP_NAME,
        "env": APP_ENV,
        "method": request.method,
        "path": request.path,
        "status": response.status_code,
        "subject": g.get("auth_subject", "anonymous"),
        "client_ip": request.remote_addr,
        "duration_ms": duration_ms,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    _audit.info(json.dumps(record))
    return response


# ---------------------------------------------------------------------------
# Auth decorator — the Authorization header must equal the static API_SECRET
# ---------------------------------------------------------------------------
def auth_required(fn):
    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        if not API_SECRET:
            # Fail closed: never match against an unset/empty secret.
            return jsonify({"error": "server auth secret not configured"}), 503
        auth = request.headers.get("Authorization", "")
        if not hmac.compare_digest(auth.encode(), API_SECRET.encode()):
            return jsonify({"error": "invalid credentials"}), 401
        g.auth_subject = "api-secret"
        return fn(*args, **kwargs)
    return wrapper


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.get("/status")
def status():
    """No-auth health/status endpoint."""
    return jsonify({
        "app": APP_NAME,
        "env": APP_ENV,
        "status": "ok",
    })


@app.get("/message")
@auth_required
def get_message():
    """
    Fetch a key/value from Web App B (Redis store).
    Query param: ?key=<redis-key>  (defaults to 'greeting')
    """
    key = request.args.get("key", "greeting")
    try:
        resp = requests.get(
            f"{WEB_APP_B_URL}/get",
            params={"key": key},
            headers={"Authorization": request.headers.get("Authorization")},
            timeout=5,
        )
        if resp.status_code == 404:
            # Key not found in Redis — a client-side miss, not a gateway failure.
            # A non-JSON 404 (e.g. a routing error) raises and falls through to 502.
            return jsonify(resp.json()), 404
        resp.raise_for_status()
        return jsonify(resp.json())
    except requests.exceptions.RequestException as exc:
        return jsonify({"error": str(exc)}), 502


@app.post("/spike")
@auth_required
def cpu_spike():
    """
    Burn CPU for SPIKE_SECONDS in a background thread to trigger HPA.
    Returns immediately with the duration so the client isn't left hanging.
    """
    duration = int(request.json.get("seconds", SPIKE_SECONDS) if request.is_json else SPIKE_SECONDS)
    duration = max(1, min(duration, 120))  # clamp 1–120 s

    def _burn(secs: int):
        end = time.time() + secs
        while time.time() < end:
            # tight math loop — intentionally CPU-bound
            _ = math.sqrt(sum(i * i for i in range(10_000)))

    thread = threading.Thread(target=_burn, args=(duration,), daemon=True)
    thread.start()

    return jsonify({
        "message": f"CPU spike started for {duration} seconds",
        "triggered_by": getattr(g, "auth_subject", "unknown"),
    })


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=False)
