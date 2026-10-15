"""
Web Application B — Python/Flask microservice backed by IBM Cloud Databases (ICD) Redis
Active/Active: identical deployment in both regions; Web App A reads from whichever
cluster is local (east-west via Istio DestinationRule).

Endpoints (all cluster-internal — not exposed to the public internet):
  GET  /get?key=<k>        → retrieve value from Redis
  POST /set                → {"key": "k", "value": "v", "ttl": 60}  → store in Redis
  GET  /status             → health / connectivity check (no auth)

Access control:
  Istio AuthorizationPolicy restricts callers to web-app-a's service account only.
"""

import os
import json
import ssl
import base64
import time
import logging
import tempfile

import redis
from flask import Flask, jsonify, request, g

app = Flask(__name__)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
APP_NAME = os.environ.get("APP_NAME", "web-app-b")
APP_ENV  = os.environ.get("APP_ENV", "poc")


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
        "client_ip": request.remote_addr,
        "duration_ms": duration_ms,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    _audit.info(json.dumps(record))
    return response


# ---------------------------------------------------------------------------
# ICD Redis connection (injected from k8s Secret via Terraform outputs)
# ---------------------------------------------------------------------------
REDIS_HOST     = os.environ["REDIS_HOST"]       # VPE private hostname
REDIS_PORT     = int(os.environ.get("REDIS_PORT", "6380"))
REDIS_USERNAME = os.environ.get("REDIS_USERNAME", "admin")  # ICD Redis default user
REDIS_PASSWORD = os.environ["REDIS_PASSWORD"]
REDIS_CERT_B64 = os.environ.get("REDIS_CERT_B64", "")  # base64 TLS cert from ICD


def _decode_cert(value: str) -> bytes:
    """Return PEM bytes from raw PEM or (possibly double-encoded) base64."""
    data = value.strip().encode()
    for _ in range(3):
        if data.startswith(b"-----BEGIN"):
            return data
        try:
            data = base64.b64decode(data, validate=True)
        except ValueError:
            break
    raise ValueError(
        "REDIS_CERT_B64 is not a PEM certificate or base64-encoded PEM "
        f"(starts with {value.strip()[:12]!r}, length {len(value)})"
    )


def _build_redis_client() -> redis.Redis:
    """Create a Redis client with TLS using the ICD-provided certificate."""
    ssl_context = None
    if REDIS_CERT_B64:
        # Decode the cert and write to a temp file for ssl module
        cert_pem = _decode_cert(REDIS_CERT_B64)
        tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".pem")
        tmp.write(cert_pem)
        tmp.flush()

        ssl_context = ssl.create_default_context(cafile=tmp.name)
        ssl_context.check_hostname = True
        ssl_context.verify_mode = ssl.CERT_REQUIRED

    return redis.Redis(
        host=REDIS_HOST,
        port=REDIS_PORT,
        username=REDIS_USERNAME,
        password=REDIS_PASSWORD,
        ssl=True,
        ssl_ca_certs=tmp.name if REDIS_CERT_B64 else None,
        decode_responses=True,
        socket_connect_timeout=5,
        socket_timeout=5,
        retry_on_timeout=True,
    )


# Initialise once at startup
r = _build_redis_client()


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.get("/status")
def status():
    """No-auth health check — also verifies Redis connectivity."""
    try:
        pong = r.ping()
        return jsonify({"app": "web-app-b", "status": "ok", "redis_ping": pong})
    except redis.RedisError as exc:
        return jsonify({"app": "web-app-b", "status": "degraded", "error": str(exc)}), 503


@app.get("/get")
def get_value():
    """Return the value for a key from Redis."""
    key = request.args.get("key")
    if not key:
        return jsonify({"error": "missing query param: key"}), 400
    try:
        value = r.get(key)
        if value is None:
            return jsonify({"key": key, "value": None, "found": False}), 404
        return jsonify({"key": key, "value": value, "found": True})
    except redis.RedisError as exc:
        return jsonify({"error": str(exc)}), 503


@app.post("/set")
def set_value():
    """Store a key/value pair in Redis with an optional TTL (seconds)."""
    body = request.get_json(silent=True) or {}
    key   = body.get("key")
    value = body.get("value")
    ttl   = body.get("ttl")   # optional

    if not key or value is None:
        return jsonify({"error": "body must contain 'key' and 'value'"}), 400

    try:
        if ttl:
            r.setex(name=key, time=int(ttl), value=value)
        else:
            r.set(key, value)
        return jsonify({"key": key, "stored": True})
    except redis.RedisError as exc:
        return jsonify({"error": str(exc)}), 503


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=False)
